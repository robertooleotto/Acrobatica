"""Ortorettifica end-to-end di una sessione Supabase con bootstrap automatico
del piano del muro via ORB feature matching + RANSAC homography.

Uso:
    python scripts/run_ortho_local.py <session_prefix>

Pipeline:
  1. scarica tutte le foto (auto pre-rotate CW per allinearle a K).
  2. ORB feature match tra una coppia di foto con baseline decente.
  3. RANSAC homography → tieni solo gli inlier (≈ punti coplanari del muro).
  4. triangola ogni inlier in 3D.
  5. SVD fit_plane su tutti i punti → WallPlane.
  6. orthorectify_photo su ogni foto.
  7. composite finale + apertura in Preview.
"""
from __future__ import annotations
import sys
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import cv2
import numpy as np
from dotenv import load_dotenv

load_dotenv(ROOT / ".env")

from app.services import session_store, storage_service, triangulation_service
from app.services.triangulation_service import CameraPose
from app.services.orthorectify_service import (
    fit_plane_from_points, orthorectify_photo, composite_orthos,
)
from app.supabase_client import get_supabase


def resolve(prefix: str) -> str:
    res = get_supabase().table("facade_sessions").select("id").execute()
    matches = [r["id"] for r in (res.data or []) if r["id"].startswith(prefix)]
    if not matches:
        raise SystemExit(f"Nessuna sessione con prefisso {prefix}")
    if len(matches) > 1:
        raise SystemExit(f"Prefisso ambiguo: {matches}")
    return matches[0]


def pose_from(meta: dict) -> CameraPose:
    return CameraPose(transform=tuple(meta["camera_transform"]),
                      intrinsics=tuple(meta["camera_intrinsics"]))


def landscape_aligned(img: np.ndarray, meta: dict) -> np.ndarray:
    """Pre-rotate CW se buffer JPEG (portrait) ≠ K (landscape)."""
    h, w = img.shape[:2]
    if (w, h) != (int(meta["image_width"]), int(meta["image_height"])):
        if (h, w) == (int(meta["image_width"]), int(meta["image_height"])):
            return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    return img


def main(prefix: str) -> None:
    sid = resolve(prefix)
    photos = session_store.list_photos(sid)
    if len(photos) < 2:
        raise SystemExit("Servono almeno 2 foto.")
    print(f"Sessione: {sid}  ({len(photos)} foto)")

    # 1) Scarica + allinea tutte le foto.
    images: dict[int, np.ndarray] = {}
    for p in photos:
        raw = storage_service.download_bytes(p["storage_path"])
        img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            print(f"  [{p['order_index']}] decode fallito, skip"); continue
        images[p["order_index"]] = landscape_aligned(img, p["metadata"])
    photos_loaded = [p for p in photos if p["order_index"] in images]
    print(f"Caricate: {len(photos_loaded)} foto")

    # 2) Bootstrap MULTI-COPPIA: accumula triangolazioni da TUTTE le coppie con
    # baseline ≥ 1m. Una singola coppia spesso ha pochi inlier in una piccola
    # zona; combinandone diverse otteniamo una nuvola di punti più estesa sul muro.
    #    Baseline larga = triangolazione 3D ben condizionata; inlier alti = sufficiente
    #    overlap del muro. Score combinato bilancia i due.
    ordered = sorted(photos_loaded, key=lambda x: x["order_index"])

    def cam_pos(p: dict) -> np.ndarray:
        T = np.asarray(p["metadata"]["camera_transform"], dtype=np.float64).reshape(4, 4, order="F")
        return T[:3, 3]

    def baseline(a: dict, b: dict) -> float:
        return float(np.linalg.norm(cam_pos(a) - cam_pos(b)))

    # Tutte le coppie con baseline ≥ 1m.
    pairs = [(ordered[i], ordered[j], baseline(ordered[i], ordered[j]))
             for i in range(len(ordered)) for j in range(i + 1, len(ordered))]
    pairs = [p for p in pairs if p[2] >= 1.0]
    pairs.sort(key=lambda p: -p[2])
    print(f"Coppie con baseline ≥ 1m: {len(pairs)}")

    # Accumula triangolazioni: ogni coppia contribuisce con i suoi inlier ORB
    all_pts_3d: list[tuple[float, float, float]] = []
    used_pairs = 0
    for a_cand, b_cand, bl in pairs[:15]:
        img_a = images[a_cand["order_index"]]
        img_b = images[b_cand["order_index"]]
        orb = cv2.ORB_create(nfeatures=2000)
        kpa, dsa = orb.detectAndCompute(cv2.cvtColor(img_a, cv2.COLOR_BGR2GRAY), None)
        kpb, dsb = orb.detectAndCompute(cv2.cvtColor(img_b, cv2.COLOR_BGR2GRAY), None)
        if dsa is None or dsb is None or len(kpa) < 50 or len(kpb) < 50:
            continue
        bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
        m = sorted(bf.match(dsa, dsb), key=lambda x: x.distance)[:300]
        if len(m) < 8: continue
        pa = np.float32([kpa[x.queryIdx].pt for x in m])
        pb = np.float32([kpb[x.trainIdx].pt for x in m])
        H, mask = cv2.findHomography(pa, pb, cv2.RANSAC, 3.0)
        if H is None: continue
        inl = mask.ravel().astype(bool)
        if inl.sum() < 6: continue
        pa_in = pa[inl]; pb_in = pb[inl]
        pose_a = pose_from(a_cand["metadata"])
        pose_b = pose_from(b_cand["metadata"])
        new_pts = 0
        for (xa, ya), (xb, yb) in zip(pa_in, pb_in):
            ra = triangulation_service.ray_from_pixel(pose_a, float(xa), float(ya))
            rb = triangulation_service.ray_from_pixel(pose_b, float(xb), float(yb))
            p3 = triangulation_service.triangulate_rays([ra, rb])
            if p3 is None: continue
            # Filtra punti troppo vicini alla camera (errore numerico): distanza ≥ 1m da entrambe
            pa_pos = np.array([ra.origin.x, ra.origin.y, ra.origin.z])
            pb_pos = np.array([rb.origin.x, rb.origin.y, rb.origin.z])
            P = np.array([p3.x, p3.y, p3.z])
            if np.linalg.norm(P - pa_pos) < 1.0 or np.linalg.norm(P - pb_pos) < 1.0:
                continue
            all_pts_3d.append((p3.x, p3.y, p3.z))
            new_pts += 1
        print(f"  {a_cand['order_index']}↔{b_cand['order_index']}: "
              f"bl={bl:.2f}m inlier={int(inl.sum()):>3}  → +{new_pts} 3D")
        used_pairs += 1
    print(f"Totale punti 3D accumulati: {len(all_pts_3d)} da {used_pairs} coppie")
    if len(all_pts_3d) < 10:
        raise SystemExit("Troppi pochi punti 3D — sessione non triangolabile.")
    pts_3d = all_pts_3d


    # 6) Fit del piano via SVD (vincolato verticale per default).
    plane = fit_plane_from_points(pts_3d, pad_m=0.0)
    print(f"piano: normale={tuple(round(x,3) for x in plane.normal)}")

    # 6b) Espandi i bounds proiettando i 4 angoli del FOV di ogni foto sul piano.
    # Così l'output copre TUTTA la facciata vista dalle foto, non solo gli ORB
    # inlier che possono essere concentrati su qualche feature.
    centroid = np.array(plane.point, dtype=np.float64)
    n = np.array(plane.normal, dtype=np.float64)
    r = np.array(plane.right, dtype=np.float64)
    u_axis = np.array(plane.up, dtype=np.float64)
    us, vs = [], []
    for p in photos_loaded:
        m = p["metadata"]
        W = int(m["image_width"]); H = int(m["image_height"])
        pose = pose_from(m)
        # Uso il CENTRO + i 4 angoli del FOV. Filtri:
        #   - |cos(angolo raggio-normale)| > 0.25  (escludi raggi quasi paralleli al muro)
        #   - distanza dal centroid < 30m (escludi proiezioni fuori scala)
        for (x, y) in [(W/2, H/2), (0, 0), (W - 1, 0), (W - 1, H - 1), (0, H - 1)]:
            ray = triangulation_service.ray_from_pixel(pose, float(x), float(y))
            o = np.array([ray.origin.x, ray.origin.y, ray.origin.z])
            d = np.array([ray.direction.x, ray.direction.y, ray.direction.z])
            denom = float(np.dot(d, n))
            if abs(denom) < 0.25:  continue
            t = float(np.dot(centroid - o, n)) / denom
            if t <= 0 or t > 50:   continue
            P = o + t * d
            d2c = P - centroid
            u_p = float(np.dot(d2c, r))
            v_p = float(np.dot(d2c, u_axis))
            if abs(u_p) > 30 or abs(v_p) > 30: continue
            us.append(u_p); vs.append(v_p)
    if us and vs:
        # 2°-98° percentile per togliere outlier residui
        u_lo, u_hi = np.percentile(us, [2, 98])
        v_lo, v_hi = np.percentile(vs, [2, 98])
        pad = 0.5
        plane = type(plane)(
            point=plane.point, normal=plane.normal, right=plane.right, up=plane.up,
            u_min=float(u_lo) - pad, u_max=float(u_hi) + pad,
            v_min=float(v_lo) - pad, v_max=float(v_hi) + pad,
        )
    print(f"        bounds u=[{plane.u_min:.2f},{plane.u_max:.2f}]  "
          f"v=[{plane.v_min:.2f},{plane.v_max:.2f}]  "
          f"({plane.width_m():.1f}m × {plane.height_m():.1f}m)")

    # 7) Orthorectify tutte le foto + composite.
    out_dir = Path(f"/tmp/ortho_{sid[:8]}")
    out_dir.mkdir(parents=True, exist_ok=True)
    orthos: list[np.ndarray] = []
    paths: list[Path] = []
    for p in photos_loaded:
        try:
            ortho, info = orthorectify_photo(
                images[p["order_index"]],
                intrinsics=p["metadata"]["camera_intrinsics"],
                camera_transform=p["metadata"]["camera_transform"],
                plane=plane,
                pixels_per_meter=150,
            )
        except Exception as e:
            print(f"  [{p['order_index']}] ortho fallito: {e}"); continue
        path = out_dir / f"{p['order_index']:02d}_ortho.jpg"
        cv2.imwrite(str(path), ortho, [cv2.IMWRITE_JPEG_QUALITY, 88])
        print(f"  [{p['order_index']}] out={info.output_size}  ppm={info.pixels_per_meter:.1f}")
        orthos.append(ortho)
        paths.append(path)

    if len(orthos) >= 2:
        comp = composite_orthos(orthos)
        comp_path = out_dir / "00_composite.jpg"
        cv2.imwrite(str(comp_path), comp, [cv2.IMWRITE_JPEG_QUALITY, 90])
        print(f"\nComposite: {comp_path}  ({comp.shape[1]}×{comp.shape[0]} px)")
        paths.insert(0, comp_path)

    print(f"\nApro {len(paths)} immagini in Preview…")
    subprocess.run(["open", "-a", "Preview", *[str(p) for p in paths]], check=False)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Uso: python scripts/run_ortho_local.py <session_prefix>")
    main(sys.argv[1])
