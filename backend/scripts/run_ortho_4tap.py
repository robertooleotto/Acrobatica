"""Test della pipeline 4-tap → wall-plane → orthorectify, con coordinate
specificate manualmente (simula il tap utente).

Le coordinate `TAPS` sono in pixel del frame ARKit landscape native (image_width
× image_height da metadata). Per derivarle dalle foto-display 1600×900 in
/tmp/inspect_4tap/, moltiplica per scale (= image_width / 1600).
"""
from __future__ import annotations
import sys, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import cv2, numpy as np
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")

from app.services import session_store, storage_service, triangulation_service
from app.services.triangulation_service import CameraPose, Point3D
from app.services.orthorectify_service import (
    fit_plane_from_points, orthorectify_photo, composite_orthos, WallPlane,
)
from app.supabase_client import get_supabase

# ─────────── Sessione + tap ───────────
SESSION_PREFIX = "eb70e960"

# Coordinate in display 1600×900 dello script di ispezione → moltiplicate per
# scale per arrivare al frame ARKit landscape (image_width × image_height).
DISPLAY_SCALE = 2.4   # 3840 / 1600

# 4 angoli del frame VETRINA LVXXO. Stima iniziale; affineremo se necessario.
# Formato per corner: list di (foto_order, x_display, y_display)
TAPS_DISPLAY = {
    "TL": [(1, 170, 290), (6, 290,  50)],
    "TR": [(1, 720, 290), (6, 660,  50)],
    "BR": [(1, 720, 480), (6, 660, 330)],
    "BL": [(1, 170, 480), (6, 290, 330)],
}


def pose_from(m: dict) -> CameraPose:
    return CameraPose(transform=tuple(m["camera_transform"]),
                      intrinsics=tuple(m["camera_intrinsics"]))


def main() -> None:
    sid = [r["id"] for r in get_supabase().table("facade_sessions").select("id").execute().data
           if r["id"].startswith(SESSION_PREFIX)][0]
    photos = sorted(session_store.list_photos(sid), key=lambda x: x["order_index"])
    print(f"Sessione: {sid}")
    meta_by_idx = {p["order_index"]: p["metadata"] for p in photos}

    # 1) Triangola ogni angolo dai tap
    corners_3d: list[Point3D] = []
    for name in ["TL", "TR", "BR", "BL"]:
        taps = TAPS_DISPLAY[name]
        rays = []
        for (idx, xd, yd) in taps:
            m = meta_by_idx[idx]
            px = xd * DISPLAY_SCALE
            py = yd * DISPLAY_SCALE
            pose = pose_from(m)
            r = triangulation_service.ray_from_pixel(pose, px, py)
            rays.append(r)
        p = triangulation_service.triangulate_rays(rays)
        if p is None:
            raise SystemExit(f"Triangolazione fallita per {name}")
        print(f"  {name}: 3D = ({p.x:+.2f}, {p.y:+.2f}, {p.z:+.2f})")
        corners_3d.append(p)

    # 2) Fit del piano (vincolo verticale per facciata)
    pts = [(c.x, c.y, c.z) for c in corners_3d]
    plane = fit_plane_from_points(pts, pad_m=0.0, assume_vertical=True)
    print(f"piano: normale={tuple(round(x,3) for x in plane.normal)}")
    print(f"        bounds u=[{plane.u_min:.2f},{plane.u_max:.2f}]  "
          f"v=[{plane.v_min:.2f},{plane.v_max:.2f}]  "
          f"({plane.width_m():.1f}m × {plane.height_m():.1f}m)  (solo vetrina)")

    # 3) Estendi i bounds proiettando il FOV di TUTTE le foto sul piano
    centroid = np.array(plane.point, dtype=np.float64)
    n = np.array(plane.normal, dtype=np.float64)
    r_axis = np.array(plane.right, dtype=np.float64)
    u_axis = np.array(plane.up, dtype=np.float64)
    us, vs = [], []
    for p in photos:
        m = p["metadata"]
        W, H = int(m["image_width"]), int(m["image_height"])
        pose = pose_from(m)
        for (x, y) in [(W/2, H/2), (0, 0), (W-1, 0), (W-1, H-1), (0, H-1)]:
            ray = triangulation_service.ray_from_pixel(pose, float(x), float(y))
            o = np.array([ray.origin.x, ray.origin.y, ray.origin.z])
            d = np.array([ray.direction.x, ray.direction.y, ray.direction.z])
            denom = float(np.dot(d, n))
            if abs(denom) < 0.25: continue
            t = float(np.dot(centroid - o, n)) / denom
            if t <= 0 or t > 50: continue
            P = o + t * d
            d2c = P - centroid
            up_v = float(np.dot(d2c, r_axis))
            vp_v = float(np.dot(d2c, u_axis))
            if abs(up_v) > 30 or abs(vp_v) > 30: continue
            us.append(up_v); vs.append(vp_v)
    if us:
        u_lo, u_hi = np.percentile(us, [2, 98])
        v_lo, v_hi = np.percentile(vs, [2, 98])
        pad = 0.5
        plane = WallPlane(
            point=plane.point, normal=plane.normal, right=plane.right, up=plane.up,
            u_min=float(u_lo) - pad, u_max=float(u_hi) + pad,
            v_min=float(v_lo) - pad, v_max=float(v_hi) + pad,
        )
    print(f"        bounds estesi u=[{plane.u_min:.2f},{plane.u_max:.2f}]  "
          f"v=[{plane.v_min:.2f},{plane.v_max:.2f}]  "
          f"({plane.width_m():.1f}m × {plane.height_m():.1f}m)")

    # 4) Orthorectify tutte le foto
    out_dir = Path(f"/tmp/ortho4tap_{sid[:8]}")
    out_dir.mkdir(parents=True, exist_ok=True)
    orthos = []
    paths = []
    for p in photos:
        raw = storage_service.download_bytes(p["storage_path"])
        img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
        try:
            ortho, info = orthorectify_photo(
                img,
                intrinsics=p["metadata"]["camera_intrinsics"],
                camera_transform=p["metadata"]["camera_transform"],
                plane=plane,
                pixels_per_meter=150,
                metadata_image_size=(int(p["metadata"]["image_width"]),
                                     int(p["metadata"]["image_height"])),
            )
        except Exception as e:
            print(f"  [{p['order_index']}] ortho fallito: {e}"); continue
        path = out_dir / f"{p['order_index']:02d}_ortho.jpg"
        cv2.imwrite(str(path), ortho, [cv2.IMWRITE_JPEG_QUALITY, 88])
        print(f"  [{p['order_index']}] out={info.output_size}")
        orthos.append(ortho); paths.append(path)

    if len(orthos) >= 2:
        comp = composite_orthos(orthos)
        comp_path = out_dir / "00_composite.jpg"
        cv2.imwrite(str(comp_path), comp, [cv2.IMWRITE_JPEG_QUALITY, 90])
        print(f"\nComposite: {comp_path}  ({comp.shape[1]}×{comp.shape[0]})")
        paths.insert(0, comp_path)

    print(f"\nApro {len(paths)} file in Preview…")
    subprocess.run(["open", "-a", "Preview", *[str(p) for p in paths]], check=False)


if __name__ == "__main__":
    main()
