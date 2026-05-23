"""Replay del run tap4 più recente per a8b096e3 senza richiedere ai click —
riusa le coordinate dei tap già fatti. Iterazione veloce sulla math.

Coordinate ARKit landscape native ricavate dal run b22dn7bwm.
"""
from __future__ import annotations
import sys, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

import cv2
import numpy as np
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")

from app.services import triangulation_service
from app.services.triangulation_service import CameraPose, Point3D
from app.services.orthorectify_service import (
    fit_plane_from_points, orthorectify_photo, composite_orthos, WallPlane,
)
from _session_source import SessionSource

CORNER_NAMES = ["TL", "TR", "BR", "BL"]
TAPS = {
    0: [(1628, 1855), (808, 1871), (825, 755), (1628, 757)],
    6: [(2402, 1857), (1598, 1866), (1598, 763), (2394, 760)],
}


def landscape_aligned(img, meta):
    h, w = img.shape[:2]
    if (w, h) != (int(meta["image_width"]), int(meta["image_height"])) and \
       (h, w) == (int(meta["image_width"]), int(meta["image_height"])):
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    return img


def pose_from(meta): return CameraPose(transform=tuple(meta["camera_transform"]),
                                       intrinsics=tuple(meta["camera_intrinsics"]))


def main():
    src = SessionSource.open(str(ROOT / "data" / "fixtures" / "a8b096e3"))
    photos_by_idx = {p["order_index"]: p for p in src.photos}

    # 1) Triangola i 4 corner usando i tap salvati su foto 0 e 6
    print("Triangolazione…")
    corners_3d = []
    for ci, cname in enumerate(CORNER_NAMES):
        rays = []
        for idx, taps in TAPS.items():
            xp, yp = taps[ci]
            rays.append(triangulation_service.ray_from_pixel(
                pose_from(photos_by_idx[idx]["metadata"]), float(xp), float(yp)))
        p3 = triangulation_service.triangulate_rays(rays)
        print(f"  {cname}: ({p3.x:+.2f}, {p3.y:+.2f}, {p3.z:+.2f})")
        corners_3d.append(p3)

    # 2) Fit piano (vincolato verticale), orientato verso la posizione media camere
    mean_cam = np.mean([
        np.asarray(p["metadata"]["camera_transform"]).reshape(4,4,order="F")[:3, 3]
        for p in src.photos
    ], axis=0)
    # PROVA: assume_vertical=False per lasciare al SVD trovare il piano vero
    # (senza forzare n_y=0). Se il muro o l'ARKit-gravity hanno un piccolo
    # disallineamento, questo dovrebbe assorbirlo.
    plane = fit_plane_from_points(
        [(c.x, c.y, c.z) for c in corners_3d], pad_m=0.0, assume_vertical=False,
        face_toward=tuple(mean_cam))
    print(f"piano: normale={tuple(round(x,3) for x in plane.normal)}")
    print(f"  bounds 4-tap: u=[{plane.u_min:.2f},{plane.u_max:.2f}] "
          f"v=[{plane.v_min:.2f},{plane.v_max:.2f}]")

    # 3) Estendi bounds via FOV-projection
    centroid = np.array(plane.point); n = np.array(plane.normal)
    r_ax = np.array(plane.right); u_ax = np.array(plane.up)
    us, vs = [], []
    acc = rej_d = rej_t = rej_dist = 0
    for p in src.photos:
        m = p["metadata"]
        W, H = int(m["image_width"]), int(m["image_height"])
        pose = pose_from(m)
        for (x, y) in [(W/2, H/2), (0, 0), (W-1, 0), (W-1, H-1), (0, H-1)]:
            ray = triangulation_service.ray_from_pixel(pose, float(x), float(y))
            o = np.array([ray.origin.x, ray.origin.y, ray.origin.z])
            d = np.array([ray.direction.x, ray.direction.y, ray.direction.z])
            denom = float(np.dot(d, n))
            if abs(denom) < 0.10: rej_d += 1; continue
            t = float(np.dot(centroid - o, n)) / denom
            if t <= 0 or t > 30: rej_t += 1; continue
            P = o + t * d
            d2c = P - centroid
            up = float(np.dot(d2c, r_ax)); vp = float(np.dot(d2c, u_ax))
            if abs(up) > 15 or abs(vp) > 15: rej_dist += 1; continue
            us.append(up); vs.append(vp); acc += 1
    print(f"  FOV-projection: {acc} accettati, rejected: denom={rej_d}, t={rej_t}, dist={rej_dist}")
    if us:
        u_lo, u_hi = np.percentile(us, [2, 98])
        v_lo, v_hi = np.percentile(vs, [2, 98])
        pad = 0.3
        plane = WallPlane(
            point=plane.point, normal=plane.normal, right=plane.right, up=plane.up,
            u_min=min(plane.u_min, float(u_lo)) - pad,
            u_max=max(plane.u_max, float(u_hi)) + pad,
            v_min=min(plane.v_min, float(v_lo)) - pad,
            v_max=max(plane.v_max, float(v_hi)) + pad,
        )
    print(f"  bounds estesi: u=[{plane.u_min:.2f},{plane.u_max:.2f}] "
          f"v=[{plane.v_min:.2f},{plane.v_max:.2f}] "
          f"({plane.width_m():.1f}m × {plane.height_m():.1f}m)")

    # 4) Ortografica tutte le foto + composite
    out_dir = Path(f"/tmp/ortho4tap_a8b096e3_replay")
    out_dir.mkdir(parents=True, exist_ok=True)
    orthos = []
    paths = []
    for p in src.photos:
        img = landscape_aligned(src.load_image(p), p["metadata"])
        try:
            ortho, info = orthorectify_photo(
                img, intrinsics=p["metadata"]["camera_intrinsics"],
                camera_transform=p["metadata"]["camera_transform"],
                plane=plane, pixels_per_meter=120,
                metadata_image_size=(int(p["metadata"]["image_width"]),
                                     int(p["metadata"]["image_height"])),
            )
        except Exception as e:
            print(f"  [{p['order_index']}] ortho fallito: {e}"); continue
        path = out_dir / f"{p['order_index']:02d}_ortho.jpg"
        cv2.imwrite(str(path), ortho, [cv2.IMWRITE_JPEG_QUALITY, 88])
        orthos.append(ortho); paths.append(path)
        print(f"  [{p['order_index']}] ortho {info.output_size}")

    if len(orthos) >= 2:
        comp = composite_orthos(orthos)
        comp_path = out_dir / "00_composite.jpg"
        cv2.imwrite(str(comp_path), comp, [cv2.IMWRITE_JPEG_QUALITY, 90])
        print(f"composite: {comp_path}  ({comp.shape[1]}×{comp.shape[0]})")
        paths.insert(0, comp_path)

    subprocess.run(["open", "-a", "Preview", *[str(p) for p in paths]], check=False)


if __name__ == "__main__":
    main()
