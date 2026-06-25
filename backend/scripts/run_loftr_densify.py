"""Densificazione mirata con LoFTR (kornia, CPU): aggiunge punti 3D anche sulle
superfici lisce (facce del bovindo) dove SIFT non aggancia nulla.

LoFTR su coppie con baseline+overlap → triangolazione con pose ARKit fisse →
reiezione reproj → nuovi punti aggiunti alla nuvola sparsa → ri-segmentazione
multi-piano per vedere se emergono le facce angolate del trapezio.

Uso: python scripts/run_loftr_densify.py f604436f [--pairs 50] [--max-side 720]
"""
from __future__ import annotations
import sys, math
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))

import cv2, numpy as np, torch
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")
from kornia.feature import LoFTR
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

def project(P, pose):
    T = pose.transform; K = pose.intrinsics
    fx, fy, cx, cy = K[0], K[4], K[6], K[7]
    o = np.array([T[12], T[13], T[14]]); d = P - o
    Xc = T[0]*d[0]+T[1]*d[1]+T[2]*d[2]
    Yc = T[4]*d[0]+T[5]*d[1]+T[6]*d[2]
    Zc = T[8]*d[0]+T[9]*d[1]+T[10]*d[2]
    if Zc >= -1e-6: return None
    return (-fx*Xc/Zc+cx, fy*Yc/Zc+cy)

def resize8(img, max_side):
    h, w = img.shape[:2]
    s = min(max_side/max(h, w), 1.0)
    nw, nh = (int(w*s)//8)*8, (int(h*s)//8)*8
    return cv2.resize(img, (nw, nh)), w/nw, h/nh

def optical(T):
    return -(T[:3,:3] @ np.array([0.,0.,1.]))


def main(arg, n_pairs=50, max_side=720, reproj_px=4.0):
    src = SessionSource.open(arg)
    photos = sorted(src.photos, key=lambda p: int(p["order_index"]))
    print(f"{len(photos)} foto")

    imgs, poses, mats = {}, {}, {}
    for p in photos:
        o = int(p["order_index"]); img = src.load_image(p)
        if img is None: continue
        img = landscape_aligned(img, p["metadata"])
        imgs[o] = img; poses[o] = pose_from(p["metadata"])
        mats[o] = np.asarray(p["metadata"]["camera_transform"], np.float64).reshape(4,4,order='F')
    orders = sorted(imgs.keys())

    # seleziona coppie con baseline 0.4-8m e assi ottici entro ~28°
    pairs = []
    for i in range(len(orders)):
        for j in range(i+1, len(orders)):
            a, b = orders[i], orders[j]
            Ta, Tb = mats[a], mats[b]
            base = np.linalg.norm(Ta[:3,3]-Tb[:3,3])
            if not (0.4 <= base <= 8.0): continue
            ang = math.degrees(math.acos(max(-1,min(1, optical(Ta)@optical(Tb)))))
            if ang > 28: continue
            pairs.append((a, b, base, ang))
    pairs.sort(key=lambda x: x[3])      # prima le più allineate (max overlap)
    pairs = pairs[:n_pairs]
    print(f"coppie selezionate: {len(pairs)}")

    matcher = LoFTR(pretrained="outdoor").eval()
    cloud = []
    for k, (a, b, base, ang) in enumerate(pairs):
        ia, sxa, sya = resize8(imgs[a], max_side)
        ib, sxb, syb = resize8(imgs[b], max_side)
        ga = cv2.cvtColor(ia, cv2.COLOR_BGR2GRAY).astype(np.float32)/255.
        gb = cv2.cvtColor(ib, cv2.COLOR_BGR2GRAY).astype(np.float32)/255.
        with torch.inference_mode():
            out = matcher({"image0": torch.from_numpy(ga)[None,None],
                           "image1": torch.from_numpy(gb)[None,None]})
        k0 = out["keypoints0"].cpu().numpy(); k1 = out["keypoints1"].cpu().numpy()
        conf = out["confidence"].cpu().numpy()
        keep = conf >= 0.5
        k0, k1 = k0[keep], k1[keep]
        if len(k0) < 10:
            print(f"  [{a}-{b}] {len(k0)} match (scarsi)"); continue
        kept = 0
        for (x0,y0),(x1,y1) in zip(k0, k1):
            ra = ts.ray_from_pixel(poses[a], x0*sxa, y0*sya)
            rb = ts.ray_from_pixel(poses[b], x1*sxb, y1*syb)
            P = ts.triangulate_rays([ra, rb])
            if P is None: continue
            Pw = np.array([P.x, P.y, P.z])
            qa = project(Pw, poses[a]); qb = project(Pw, poses[b])
            if qa is None or qb is None: continue
            if math.hypot(qa[0]-x0*sxa, qa[1]-y0*sya) > reproj_px: continue
            if math.hypot(qb[0]-x1*sxb, qb[1]-y1*syb) > reproj_px: continue
            cloud.append(Pw); kept += 1
        if k % 5 == 0:
            print(f"  [{k+1}/{len(pairs)}] {a}-{b} base{base:.1f} ang{ang:.0f}: {len(k0)} match → {kept} pt 3D")

    pts = np.array(cloud)
    print(f"\nNUOVI punti LoFTR: {len(pts)}")
    # combina con la nuvola SIFT esistente
    old = []
    s=False
    for l in open(f"/tmp/sparse_{src.sid[:8]}/cloud.ply"):
        if s: old.append([float(x) for x in l.split()[:3]])
        elif l.startswith("end_header"): s=True
    old = np.array(old)
    comb = np.vstack([old, pts])
    out_ply = Path(f"/tmp/sparse_{src.sid[:8]}/cloud_dense_loftr.ply")
    with out_ply.open("w") as f:
        f.write("ply\nformat ascii 1.0\n")
        f.write(f"element vertex {len(comb)}\n")
        f.write("property float x\nproperty float y\nproperty float z\nend_header\n")
        for P in comb: f.write(f"{P[0]:.4f} {P[1]:.4f} {P[2]:.4f}\n")
    print(f"nuvola combinata: {len(old)} SIFT + {len(pts)} LoFTR = {len(comb)} → {out_ply}")


if __name__ == "__main__":
    arg = sys.argv[1]; raw = sys.argv[2:]
    npr, ms = 50, 720
    if "--pairs" in raw: i=raw.index("--pairs"); npr=int(raw[i+1])
    if "--max-side" in raw: i=raw.index("--max-side"); ms=int(raw[i+1])
    main(arg, n_pairs=npr, max_side=ms)
