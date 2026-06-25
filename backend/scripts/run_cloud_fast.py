"""Nuvola pose-prior VELOCE: SIFT + triangolazione con pose ARKit fisse, ma con
filtro coppie intelligente (finestra di vicini + baseline + angolo vista) così
NON esplode su sessioni con tante foto. Tutto locale, CPU, niente pod.

Uso: python scripts/run_cloud_fast.py 1553ab3c [--every 3] [--max-dim 1600]
     [--window 25] [--max-base 4.0] [--max-ang 35] [--reproj-px 4]
"""
from __future__ import annotations
import sys, math, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))

import cv2, numpy as np
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")
from app.services import triangulation_service as ts
from app.services.triangulation_service import CameraPose
from _session_source import SessionSource


def landscape_aligned(img, meta):
    h, w = img.shape[:2]
    mw, mh = int(meta["image_width"]), int(meta["image_height"])
    if (w, h) != (mw, mh) and (h, w) == (mw, mh):
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    return img

def pose_from(meta):
    return CameraPose(transform=tuple(meta["camera_transform"]),
                      intrinsics=tuple(meta["camera_intrinsics"]))

def optical(T):  # asse ottico world (camera guarda -Z): -col2
    return -np.array([T[8], T[9], T[10]])

def center(T):
    return np.array([T[12], T[13], T[14]])

def project(pose, P):
    T = pose.transform; K = pose.intrinsics
    fx, fy, cx, cy = K[0], K[4], K[6], K[7]
    o = center(T); d = P - o
    Xc = T[0]*d[0]+T[1]*d[1]+T[2]*d[2]
    Yc = T[4]*d[0]+T[5]*d[1]+T[6]*d[2]
    Zc = T[8]*d[0]+T[9]*d[1]+T[10]*d[2]
    if Zc >= -1e-6: return None
    return (-fx*Xc/Zc+cx, fy*Yc/Zc+cy)


def main(arg, every=3, max_dim=1600, window=25, max_base=4.0, max_ang=35.0, reproj_px=4.0, ratio=0.75):
    t0 = time.time()
    src = SessionSource.open(arg)
    photos = sorted(src.photos, key=lambda p: int(p["order_index"]))
    photos = photos[::every]
    print(f"Sessione {src.sid[:8]}: {len(photos)} foto (1 ogni {every})")

    sift = cv2.SIFT_create(nfeatures=6000)
    feats = {}
    for idx, p in enumerate(photos):
        img = src.load_image(p)
        if img is None: continue
        img = landscape_aligned(img, p["metadata"])
        H, W = img.shape[:2]; s = min(max_dim/max(H, W), 1.0)
        small = cv2.resize(img, (int(W*s), int(H*s)), interpolation=cv2.INTER_AREA) if s < 1 else img
        kp, des = sift.detectAndCompute(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), None)
        if des is None or len(kp) < 50: continue
        inv = 1.0/s
        kpn = np.array([[k.pt[0]*inv, k.pt[1]*inv] for k in kp], np.float64)
        T = p["metadata"]["camera_transform"]
        feats[idx] = {"kp": kpn, "des": des, "pose": pose_from(p["metadata"]),
                      "c": center(T), "ax": optical(T)/np.linalg.norm(optical(T))}
    keys = sorted(feats.keys())
    print(f"SIFT fatto su {len(keys)} foto ({time.time()-t0:.0f}s)")

    bf = cv2.BFMatcher(cv2.NORM_L2)
    cloud, rgb = [], []
    npairs = 0
    for a_i in range(len(keys)):
        for b_i in range(a_i+1, len(keys)):
            ka, kb = keys[a_i], keys[b_i]
            if abs(ka - kb) > window: continue                     # finestra vicini
            fa, fb = feats[ka], feats[kb]
            base = np.linalg.norm(fa["c"] - fb["c"])
            if base < 0.15 or base > max_base: continue            # baseline utile
            ang = math.degrees(math.acos(max(-1, min(1, fa["ax"] @ fb["ax"]))))
            if ang > max_ang: continue                             # vista simile
            knn = bf.knnMatch(fa["des"], fb["des"], k=2)
            good = [m for m, n in (pr for pr in knn if len(pr) == 2) if m.distance < ratio*n.distance]
            if len(good) < 12: continue
            pa = np.array([fa["kp"][m.queryIdx] for m in good])
            pb = np.array([fb["kp"][m.trainIdx] for m in good])
            F, mask = cv2.findFundamentalMat(pa, pb, cv2.FM_RANSAC, 3.0, 0.99)
            if F is None or mask is None: continue
            mask = mask.ravel().astype(bool); pa, pb = pa[mask], pb[mask]
            npairs += 1
            for (xa, ya), (xb, yb) in zip(pa, pb):
                ra = ts.ray_from_pixel(fa["pose"], float(xa), float(ya))
                rb = ts.ray_from_pixel(fb["pose"], float(xb), float(yb))
                P = ts.triangulate_rays([ra, rb])
                if P is None: continue
                Pw = np.array([P.x, P.y, P.z])
                qa = project(fa["pose"], Pw); qb = project(fb["pose"], Pw)
                if qa is None or qb is None: continue
                if math.hypot(qa[0]-xa, qa[1]-ya) > reproj_px: continue
                if math.hypot(qb[0]-xb, qb[1]-yb) > reproj_px: continue
                cloud.append(Pw)
    pts = np.array(cloud)
    print(f"Coppie usate: {npairs} | punti nuvola: {len(pts)} | tempo TOT {time.time()-t0:.0f}s")
    if len(pts) == 0: return
    out = Path(f"/tmp/cloud_fast_{src.sid[:8]}"); out.mkdir(exist_ok=True)
    ply = out / "cloud.ply"
    with ply.open("w") as f:
        f.write(f"ply\nformat ascii 1.0\nelement vertex {len(pts)}\n")
        f.write("property float x\nproperty float y\nproperty float z\nend_header\n")
        for P in pts: f.write(f"{P[0]:.4f} {P[1]:.4f} {P[2]:.4f}\n")
    print("salvato", ply)


if __name__ == "__main__":
    arg = sys.argv[1]; raw = sys.argv[2:]
    kw = {}
    for k, name, conv in [("--every","every",int),("--max-dim","max_dim",int),
                          ("--window","window",int),("--max-base","max_base",float),
                          ("--max-ang","max_ang",float),("--reproj-px","reproj_px",float)]:
        if k in raw: i = raw.index(k); kw[name] = conv(raw[i+1])
    main(arg, **kw)
