"""Da nuvola sparsa pose-prior → piano facciata auto → ortho metrico.

Riusa /tmp/sparse_<sid>/cloud.ply (prodotto da run_sparse_planes_local.py),
senza rifare SIFT/match. Pipeline:
  1. Carica la nuvola.
  2. Statistical outlier removal (kNN).
  3. RANSAC: piano dominante = facciata frontale.
  4. fit_plane_from_points sugli inlier (assume_vertical, face_toward=camere).
  5. Filtra le foto che guardano il piano (angolo < max), orthorectify ognuna.
  6. composite_orthos → ortho metrico, salva + apri.

Uso:
    python scripts/run_cloud_ortho_local.py 857a6303 [--max-angle 50] [--dist 0.15] [--ppm 150]
"""
from __future__ import annotations
import sys, math, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))

import cv2
import numpy as np
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")

from app.services.orthorectify_service import (
    fit_plane_from_points, orthorectify_photo, composite_orthos,
    composite_orthos_multiband, composite_orthos_graphcut, WallPlane,
)
from _session_source import SessionSource


def load_ply(path: Path) -> np.ndarray:
    pts = []
    with path.open() as f:
        started = False
        for l in f:
            if started:
                x, y, z = map(float, l.split()[:3]); pts.append((x, y, z))
            elif l.startswith("end_header"):
                started = True
    return np.array(pts)


def statistical_outlier_removal(pts: np.ndarray, k: int = 12, std_mul: float = 2.0) -> np.ndarray:
    """Rimuove punti la cui distanza media ai k vicini è > media + std_mul*std.
    Implementazione O(N^2) semplice (ok per qualche migliaio di punti)."""
    n = len(pts)
    if n <= k + 1:
        return pts
    # distanza media ai k vicini, a blocchi per non saturare RAM
    mean_d = np.empty(n)
    for i in range(0, n, 500):
        block = pts[i:i+500]
        d2 = ((block[:, None, :] - pts[None, :, :]) ** 2).sum(-1)
        d2.sort(axis=1)
        mean_d[i:i+len(block)] = np.sqrt(d2[:, 1:k+1]).mean(1)
    thr = mean_d.mean() + std_mul * mean_d.std()
    return pts[mean_d < thr]


def ransac_plane(pts: np.ndarray, dist_thresh: float, iters: int = 2000):
    rng = np.random.default_rng(0)
    best_inl = None
    for _ in range(iters):
        s = pts[rng.choice(len(pts), 3, replace=False)]
        n = np.cross(s[1]-s[0], s[2]-s[0])
        nn = np.linalg.norm(n)
        if nn < 1e-9:
            continue
        n /= nn; d = -float(n @ s[0])
        inl = np.abs(pts @ n + d) < dist_thresh
        if best_inl is None or inl.sum() > best_inl.sum():
            best_inl = inl
    return best_inl


def landscape_aligned_size(meta, img):
    h, w = img.shape[:2]
    mw, mh = int(meta["image_width"]), int(meta["image_height"])
    if (w, h) != (mw, mh) and (h, w) == (mw, mh):
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    return img


def main(arg: str, max_angle: float = 50.0, dist: float = 0.15, ppm: float = 150.0,
         blend: str = "multiband", pitch_step_deg: float = 0.0):
    sid_dir = None
    src = SessionSource.open(arg)
    sid = src.sid
    # Scrematura raffica per la fase ortho (0 = usa tutte le foto)
    photos_use = src.photos
    if pitch_step_deg > 0:
        from app.services.frame_selection import decimate_by_pitch
        photos_use = decimate_by_pitch(src.photos, pitch_step_deg=pitch_step_deg)
        print(f"Scrematura pitch {pitch_step_deg}°: {len(src.photos)} → {len(photos_use)} foto per ortho")
    cloud_path = Path(f"/tmp/sparse_{sid[:8]}/cloud.ply")
    if not cloud_path.exists():
        raise SystemExit(f"Nuvola non trovata: {cloud_path}. Lancia prima run_sparse_planes_local.py")
    pts = load_ply(cloud_path)
    print(f"Nuvola: {len(pts)} punti, spread {np.round(pts.max(0)-pts.min(0),2)}")

    # 1. Outlier removal
    pts = statistical_outlier_removal(pts, k=12, std_mul=2.0)
    print(f"Dopo SOR: {len(pts)} punti, spread {np.round(pts.max(0)-pts.min(0),2)}")

    # 2. NORMALE dal consenso delle camere (robusta), NON da RANSAC sulla nuvola.
    #    L'operatore inquadra ~perpendicolare al muro → media direzione di vista
    #    = normale facciata. Vincolata orizzontale (assume_vertical).
    opticals = []
    for p in src.photos:
        T = np.asarray(p["metadata"]["camera_transform"], dtype=np.float64).reshape(4,4,order='F')
        opt = -(T[:3,:3] @ np.array([0.0, 0.0, 1.0]))
        opt[1] = 0.0
        nn = np.linalg.norm(opt)
        if nn > 1e-6:
            opticals.append(opt / nn)
    mean_opt = np.mean(opticals, axis=0); mean_opt /= np.linalg.norm(mean_opt)
    normal = -mean_opt   # punta dal muro verso le camere
    normal /= np.linalg.norm(normal)
    up_axis = np.array([0.0, 1.0, 0.0])
    right_axis = np.cross(up_axis, normal); right_axis /= np.linalg.norm(right_axis)
    print(f"normale (consenso camere): {np.round(normal,3)}  "
          f"yaw={math.degrees(math.atan2(normal[0],normal[2])):.1f}°")

    # 3. SELEZIONE punti facciata via RANSAC a normale libera (cattura la
    #    superficie del muro anche se la nuvola è "diagonale"). L'orientamento
    #    del piano ortho però resta quello del consenso camere (sopra).
    sel = ransac_plane(pts, dist_thresh=dist)
    facade_pts = pts[sel]
    print(f"Punti facciata (RANSAC selezione): {len(facade_pts)} su {len(pts)}")

    # 4. Bounds robusti (percentili 2-98) sugli inlier proiettati su right/up
    centroid = facade_pts.mean(0)
    us = (facade_pts - centroid) @ right_axis
    vs = (facade_pts - centroid) @ up_axis
    u_lo, u_hi = np.percentile(us, [2, 98])
    v_lo, v_hi = np.percentile(vs, [2, 98])
    pad = 0.3
    plane = WallPlane(
        point=tuple(float(x) for x in centroid),
        normal=tuple(float(x) for x in normal),
        right=tuple(float(x) for x in right_axis),
        up=tuple(float(x) for x in up_axis),
        u_min=float(u_lo)-pad, u_max=float(u_hi)+pad,
        v_min=float(v_lo)-pad, v_max=float(v_hi)+pad,
    )
    print(f"       bounds robusti {plane.width_m():.1f}m × {plane.height_m():.1f}m")

    # 4. Ortho per foto, con filtro angolo
    out_dir = Path(f"/tmp/sparse_{sid[:8]}/ortho")
    out_dir.mkdir(parents=True, exist_ok=True)
    n_plane = np.array(plane.normal)
    cos_max = math.cos(math.radians(max_angle))
    orthos, paths, skipped = [], [], []
    for p in sorted(photos_use, key=lambda x: int(x["order_index"])):
        o = int(p["order_index"]); m = p["metadata"]
        T = np.asarray(m["camera_transform"], dtype=np.float64).reshape(4,4,order='F')
        optical = -(T[:3,:3] @ np.array([0.0, 0.0, 1.0]))
        cosang = float(np.dot(optical, -n_plane))
        if cosang < cos_max:
            skipped.append((o, math.degrees(math.acos(max(-1,min(1,cosang)))))); continue
        img = src.load_image(p)
        if img is None: continue
        try:
            ortho, info = orthorectify_photo(
                img, intrinsics=m["camera_intrinsics"], camera_transform=m["camera_transform"],
                plane=plane, pixels_per_meter=ppm,
                metadata_image_size=(int(m["image_width"]), int(m["image_height"])),
            )
        except Exception as e:
            print(f"  [{o}] ortho fallito: {e}"); continue
        orthos.append(ortho)
        pth = out_dir / f"{o:02d}_ortho.jpg"
        cv2.imwrite(str(pth), ortho, [cv2.IMWRITE_JPEG_QUALITY, 88]); paths.append(pth)
    if skipped:
        print("Foto scartate (angolo): " + ", ".join(f"#{o}({a:.0f}°)" for o, a in skipped))
    print(f"Foto incluse: {len(orthos)}")

    if len(orthos) >= 1:
        if len(orthos) == 1:
            comp = orthos[0]
        elif blend == "graphcut":
            comp = composite_orthos_graphcut(orthos, num_bands=5)
        elif blend == "multiband":
            comp = composite_orthos_multiband(orthos, num_bands=5)
        else:
            comp = composite_orthos(orthos, method="best_source")
        comp_path = Path(f"/tmp/sparse_{sid[:8]}/facade_auto_ortho_{blend}.jpg")
        cv2.imwrite(str(comp_path), comp, [cv2.IMWRITE_JPEG_QUALITY, 92])
        print(f"\n→ {comp_path}  ({comp.shape[1]}×{comp.shape[0]})")
        import subprocess
        subprocess.run(["open", "-a", "Preview", str(comp_path)], check=False)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Uso: python scripts/run_cloud_ortho_local.py <sid> [--max-angle D] [--dist M] [--ppm N]")
    arg = sys.argv[1]; raw = sys.argv[2:]
    ma, ds, pm, bl = 50.0, 0.15, 150.0, "graphcut"
    if "--max-angle" in raw: i=raw.index("--max-angle"); ma=float(raw[i+1]); del raw[i:i+2]
    if "--dist" in raw: i=raw.index("--dist"); ds=float(raw[i+1]); del raw[i:i+2]
    if "--ppm" in raw: i=raw.index("--ppm"); pm=float(raw[i+1]); del raw[i:i+2]
    if "--blend" in raw: i=raw.index("--blend"); bl=raw[i+1]; del raw[i:i+2]
    ps = 0.0
    if "--pitch-step" in raw: i=raw.index("--pitch-step"); ps=float(raw[i+1]); del raw[i:i+2]
    main(arg, max_angle=ma, dist=ds, ppm=pm, blend=bl, pitch_step_deg=ps)
