"""Pose-prior sparse reconstruction + multi-plane segmentation (CPU, no COLMAP).

Idea (vedi discussione 2026-05-28): COLMAP from-scratch su sweep laterale di
facciata ripetitiva collassa la nuvola (minimo degenere). Ma le pose ARKit sono
note e metriche. Quindi:

  1. SIFT (cv2) su ogni foto, nel frame landscape ARKit (coerente con K).
  2. Match a coppie: Lowe ratio + RANSAC fondamentale (toglie match spuri).
  3. Triangolazione di OGNI match con le POSE ARKIT FISSE (triangulation_service).
  4. Reiezione per errore di riproiezione (i match spuri fra finestre diverse
     danno errore alto → scartati). → nuvola SPARSA metrica nel frame ARKit.
  5. RANSAC multi-piano sulla nuvola → N facciate (frontale + spigolo ...).
  6. [TODO step 2] ortho per piano.

Per ora lo script si ferma al punto 5 e stampa diagnostica + salva PLY.

Uso:
    python scripts/run_sparse_planes_local.py <sid_prefix|fixture_dir>
    python scripts/run_sparse_planes_local.py 857a6303 --max-dim 1600 --reproj-px 4
"""
from __future__ import annotations
import sys, math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

import cv2
import numpy as np
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")

from app.services import triangulation_service as ts
from app.services.triangulation_service import CameraPose
from _session_source import SessionSource


def landscape_aligned(img: np.ndarray, meta: dict) -> np.ndarray:
    """Allinea il buffer al frame landscape ARKit (w,h)=(image_width,image_height),
    lo stesso in cui sono definite le intrinsics K."""
    h, w = img.shape[:2]
    mw, mh = int(meta["image_width"]), int(meta["image_height"])
    if (w, h) != (mw, mh) and (h, w) == (mw, mh):
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    return img


def pose_from(meta: dict) -> CameraPose:
    return CameraPose(transform=tuple(meta["camera_transform"]),
                      intrinsics=tuple(meta["camera_intrinsics"]))


def project(P: np.ndarray, pose: CameraPose) -> tuple[float, float] | None:
    """Proietta un punto 3D world → pixel nel frame ARKit. None se dietro la camera.
    Inversa esatta di ray_from_pixel."""
    T = pose.transform
    K = pose.intrinsics
    fx, fy, cx, cy = K[0], K[4], K[6], K[7]
    o = np.array([T[12], T[13], T[14]])
    d = P - o
    # R columns = camera axes in world: x=(T0,T1,T2), y=(T4,T5,T6), z=(T8,T9,T10)
    Xc = T[0]*d[0] + T[1]*d[1] + T[2]*d[2]
    Yc = T[4]*d[0] + T[5]*d[1] + T[6]*d[2]
    Zc = T[8]*d[0] + T[9]*d[1] + T[10]*d[2]
    if Zc >= -1e-6:   # ARKit guarda lungo -Z: punto davanti => Zc < 0
        return None
    px = -fx * Xc / Zc + cx
    py =  fy * Yc / Zc + cy
    return (px, py)


def main(arg: str, max_dim: int = 1600, reproj_px: float = 4.0,
         ratio: float = 0.75, max_depth_m: float = 40.0,
         pitch_step_deg: float = 0.0) -> None:
    src = SessionSource.open(arg)
    photos = sorted(src.photos, key=lambda p: int(p["order_index"]))
    print(f"Sessione: {src.source_label}  ({len(photos)} foto)")

    # Scrematura raffica → ~1 frame ogni pitch_step_deg per colonna (0 = nessuna).
    if pitch_step_deg > 0:
        from app.services.frame_selection import decimate_by_pitch
        kept = decimate_by_pitch(photos, pitch_step_deg=pitch_step_deg)
        print(f"Scrematura pitch {pitch_step_deg}°: {len(photos)} → {len(kept)} foto")
        photos = kept

    # 1. SIFT su ogni foto (downscale per velocità, keypoints riscalati al frame nativo)
    sift = cv2.SIFT_create(nfeatures=6000)
    feats: dict[int, dict] = {}   # order → {kp_native: Nx2, des: NxD, pose}
    for p in photos:
        o = int(p["order_index"])
        img = src.load_image(p)
        if img is None:
            print(f"  [{o}] decode fallito"); continue
        img = landscape_aligned(img, p["metadata"])
        H, W = img.shape[:2]
        s = min(max_dim / max(H, W), 1.0)
        small = cv2.resize(img, (int(W*s), int(H*s)), interpolation=cv2.INTER_AREA) if s < 1 else img
        gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
        kp, des = sift.detectAndCompute(gray, None)
        if des is None or len(kp) < 50:
            print(f"  [{o}] poche feature ({0 if des is None else len(kp)})"); continue
        inv = 1.0 / s
        kp_native = np.array([[k.pt[0]*inv, k.pt[1]*inv] for k in kp], dtype=np.float64)
        feats[o] = {"kp": kp_native, "des": des, "pose": pose_from(p["metadata"])}
        print(f"  [{o}] {len(kp)} feature")

    orders = sorted(feats.keys())
    print(f"\nFoto con feature: {len(orders)}")

    # 2-4. Match a coppie + triangolazione pose-prior + reiezione reproj
    bf = cv2.BFMatcher(cv2.NORM_L2)
    cloud: list[np.ndarray] = []
    cloud_rgb: list[tuple[int, int, int]] = []
    pair_stats = []
    for ii in range(len(orders)):
        for jj in range(ii + 1, len(orders)):
            oa, ob = orders[ii], orders[jj]
            fa, fb = feats[oa], feats[ob]
            # baseline: salta coppie con baseline troppo piccola (triangolazione instabile)
            Ta, Tb = fa["pose"].transform, fb["pose"].transform
            base = math.dist((Ta[12], Ta[13], Ta[14]), (Tb[12], Tb[13], Tb[14]))
            if base < 0.15:
                continue
            knn = bf.knnMatch(fa["des"], fb["des"], k=2)
            good = [m for m, n in (pair for pair in knn if len(pair) == 2)
                    if m.distance < ratio * n.distance]
            if len(good) < 12:
                continue
            pa = np.array([fa["kp"][m.queryIdx] for m in good])
            pb = np.array([fb["kp"][m.trainIdx] for m in good])
            # RANSAC fondamentale per togliere match geometricamente impossibili
            F, mask = cv2.findFundamentalMat(pa, pb, cv2.FM_RANSAC, 3.0, 0.99)
            if F is None or mask is None:
                continue
            mask = mask.ravel().astype(bool)
            pa, pb = pa[mask], pb[mask]
            kept = 0
            for (xa, ya), (xb, yb) in zip(pa, pb):
                ra = ts.ray_from_pixel(fa["pose"], float(xa), float(ya))
                rb = ts.ray_from_pixel(fb["pose"], float(xb), float(yb))
                P = ts.triangulate_rays([ra, rb])
                if P is None:
                    continue
                Pw = np.array([P.x, P.y, P.z])
                # depth check
                if math.dist((P.x, P.y, P.z), (Ta[12], Ta[13], Ta[14])) > max_depth_m:
                    continue
                # reprojection error in entrambe
                qa = project(Pw, fa["pose"]); qb = project(Pw, fb["pose"])
                if qa is None or qb is None:
                    continue
                ea = math.hypot(qa[0]-xa, qa[1]-ya)
                eb = math.hypot(qb[0]-xb, qb[1]-yb)
                if ea > reproj_px or eb > reproj_px:
                    continue
                cloud.append(Pw)
                kept += 1
            pair_stats.append((oa, ob, len(good), int(mask.sum()), kept, base))

    print(f"\nCoppie processate: {len(pair_stats)}")
    print(f"{'a':>3} {'b':>3} {'ratio':>6} {'ransac':>6} {'tri':>5} {'base_m':>7}")
    for oa, ob, g, r, k, base in pair_stats:
        print(f"{oa:>3} {ob:>3} {g:>6} {r:>6} {k:>5} {base:>7.2f}")

    if len(cloud) < 50:
        raise SystemExit(f"\nNuvola troppo piccola: {len(cloud)} punti. "
                         "Pose-prior non ha prodotto abbastanza punti.")

    pts = np.array(cloud)
    print(f"\n=== NUVOLA SPARSA: {len(pts)} punti ===")
    print(f"  spread per axis (m): {np.round(pts.max(0) - pts.min(0), 2)}")
    print(f"  estensione totale:   {float(np.linalg.norm(pts.max(0)-pts.min(0))):.2f} m")
    print(f"  centroid:            {np.round(pts.mean(0), 2)}")

    # Confronto con estensione camere ARKit (sanity)
    cams = np.array([[f["pose"].transform[12], f["pose"].transform[13],
                      f["pose"].transform[14]] for f in feats.values()])
    print(f"  (camere ARKit extent: {float(np.linalg.norm(cams.max(0)-cams.min(0))):.2f} m)")

    # Salva PLY per ispezione
    out_dir = Path(f"/tmp/sparse_{src.sid[:8]}")
    out_dir.mkdir(parents=True, exist_ok=True)
    ply = out_dir / "cloud.ply"
    with ply.open("w") as f:
        f.write("ply\nformat ascii 1.0\n")
        f.write(f"element vertex {len(pts)}\n")
        f.write("property float x\nproperty float y\nproperty float z\n")
        f.write("end_header\n")
        for P in pts:
            f.write(f"{P[0]:.4f} {P[1]:.4f} {P[2]:.4f}\n")
    print(f"\nPLY salvato: {ply}")

    # 5. RANSAC multi-piano (sequenziale: trova piano dominante, rimuovi inlier, ripeti)
    print("\n=== RANSAC multi-piano ===")
    planes = ransac_multi_plane(pts, dist_thresh=0.10, min_inliers=80, max_planes=4)
    for i, (n, d, inl) in enumerate(planes):
        print(f"  piano {i+1}: normale={np.round(n,3)}  d={d:.2f}  inliers={inl.sum()}")


def ransac_multi_plane(pts: np.ndarray, dist_thresh: float = 0.10,
                       min_inliers: int = 80, max_planes: int = 4,
                       iters: int = 1000):
    """Trova fino a max_planes piani dominanti, sequenzialmente.
    Ritorna lista di (normal(3,), d, inlier_mask) con piano: n·X + d = 0."""
    remaining = np.ones(len(pts), dtype=bool)
    results = []
    rng = np.random.default_rng(0)
    for _ in range(max_planes):
        idx = np.where(remaining)[0]
        if len(idx) < min_inliers:
            break
        sub = pts[idx]
        best_inl, best_plane = None, None
        for _ in range(iters):
            s = sub[rng.choice(len(sub), 3, replace=False)]
            v1, v2 = s[1] - s[0], s[2] - s[0]
            n = np.cross(v1, v2)
            nn = np.linalg.norm(n)
            if nn < 1e-9:
                continue
            n = n / nn
            d = -float(n @ s[0])
            dist = np.abs(sub @ n + d)
            inl = dist < dist_thresh
            if best_inl is None or inl.sum() > best_inl.sum():
                best_inl, best_plane = inl, (n, d)
        if best_inl is None or best_inl.sum() < min_inliers:
            break
        # refit SVD sugli inlier
        pin = sub[best_inl]
        c = pin.mean(0)
        _, _, vh = np.linalg.svd(pin - c)
        n = vh[-1]; n = n / np.linalg.norm(n)
        d = -float(n @ c)
        full_dist = np.abs(pts @ n + d)
        full_inl = (full_dist < dist_thresh) & remaining
        results.append((n, d, full_inl))
        remaining &= ~full_inl
    return results


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Uso: python scripts/run_sparse_planes_local.py <sid|fixture> "
                         "[--max-dim N] [--reproj-px F]")
    arg = sys.argv[1]
    raw = sys.argv[2:]
    md, rp, ps = 1600, 4.0, 0.0
    if "--max-dim" in raw:
        i = raw.index("--max-dim"); md = int(raw[i+1]); del raw[i:i+2]
    if "--reproj-px" in raw:
        i = raw.index("--reproj-px"); rp = float(raw[i+1]); del raw[i:i+2]
    if "--pitch-step" in raw:
        i = raw.index("--pitch-step"); ps = float(raw[i+1]); del raw[i:i+2]
    main(arg, max_dim=md, reproj_px=rp, pitch_step_deg=ps)
