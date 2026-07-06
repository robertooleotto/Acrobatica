#!/usr/bin/env python3
"""Prototipo LOCALE: registrazione foto su piano facciata via Bundle Adjustment
planare OC-free (photo↔photo), come da discussione con Gemini.

Pipeline (due stadi):
  1) TIE-POINT robusti: SIFT + matching, filtro EPIPOLARE con F calcolata DALLE
     POSE ARKit (mai dai match → niente salti di finestra su facciata periodica).
     Tracce multi-vista (union-find), si tengono le OSSERVAZIONI 2D.
  2) BA PLANARE (scipy.optimize.least_squares, Jacobiano sparso, loss Huber):
     ogni punto vive sul piano (Z=0), ogni camera ha 3 DOF (shiftX, shiftY,
     focalScale). Niente texture OC nel costo → la precisione non eredita l'OC.

Init: pose ARKit (δ=0) + triangolazione DLT proiettata sul piano. Maschera
parallasse: si tengono solo i punti entro ±BANDA dal piano (il filo-muro).

NON è produzione: serve a misurare i residui (mediano/p90) e confrontarli col
target v22 (1.86 / 6.17 px). Uso:
  backend/venv/bin/python backend/scripts/bundle_planar_local.py --step 3 --max-pairs 6
"""
import argparse
import json
import time
from itertools import combinations
from pathlib import Path

import cv2
import numpy as np
from scipy.optimize import least_squares
from scipy.sparse import lil_matrix

PHOTOS_DIR = Path("/Users/liscio/Acrobatica/backend/data/fixtures/6cdcb8ff/photos")
PHOTOS_JSON = Path("/Users/liscio/Acrobatica/backend/data/fixtures/6cdcb8ff/photos.json")
D = np.diag([1.0, -1.0, -1.0])   # ARKit (z davanti negativa) -> OpenCV std


# ----------------------------- camere -----------------------------

def load_cams():
    data = json.load(open(PHOTOS_JSON))
    cams = []
    for ph in data:
        m = ph["metadata"]
        T = np.array(m["camera_transform"], float).reshape(4, 4, order="F")
        K9 = m["camera_intrinsics"]
        K = np.array([[K9[0], 0, K9[6]], [0, K9[4], K9[7]], [0, 0, 1.0]])
        R, C = T[:3, :3], T[:3, 3]
        R_cv = D @ R.T
        t_cv = -R_cv @ C
        wn = m.get("wall_normal_world")
        wall_n = np.array(wn, float) if (isinstance(wn, (list, tuple)) and len(wn) == 3) else np.array([0, 0, 1.0])
        cams.append(dict(
            idx=m["order_index"], path=PHOTOS_DIR / f"{m['order_index']:04d}.jpg",
            K=K, C=C, R_cv=R_cv, t_cv=t_cv, P=K @ np.hstack([R_cv, t_cv[:, None]]),
            fwd=-R[:, 2], wall_n=wall_n))
    cams.sort(key=lambda c: c["idx"])
    return cams


def fundamental(ca, cb):
    """F (b<-a) dalle pose note: F = K_b^-T [t]_x R K_a^-1, su convenzione OpenCV."""
    Rrel = cb["R_cv"] @ ca["R_cv"].T
    trel = cb["t_cv"] - Rrel @ ca["t_cv"]
    tx = np.array([[0, -trel[2], trel[1]], [trel[2], 0, -trel[0]], [-trel[1], trel[0], 0]])
    E = tx @ Rrel
    return np.linalg.inv(cb["K"]).T @ E @ np.linalg.inv(ca["K"])


def epi_dist(F, pa, pb):
    """Distanza epipolare simmetrica (px)."""
    pa1 = np.hstack([pa, np.ones((len(pa), 1))])
    pb1 = np.hstack([pb, np.ones((len(pb), 1))])
    la = (F @ pa1.T).T        # linee in b
    lb = (F.T @ pb1.T).T      # linee in a
    da = np.abs(np.sum(pb1 * la, 1)) / np.linalg.norm(la[:, :2], axis=1)
    db = np.abs(np.sum(pa1 * lb, 1)) / np.linalg.norm(lb[:, :2], axis=1)
    return np.maximum(da, db)


# ----------------------------- matching -----------------------------

def detect(cams, scale, nfeat):
    sift = cv2.SIFT_create(nfeatures=nfeat)
    feats = []
    for c in cams:
        im = cv2.imread(str(c["path"]), cv2.IMREAD_GRAYSCALE)
        if im is None:
            feats.append((np.empty((0, 2)), None)); continue
        small = cv2.resize(im, (0, 0), fx=scale, fy=scale)
        kp, de = sift.detectAndCompute(small, None)
        pts = np.array([k.pt for k in kp], float) / scale if kp else np.empty((0, 2))
        feats.append((pts, de))
    return feats


def select_pairs(cams, max_pairs, min_base, max_base, max_ang):
    pairs = []
    for i, ca in enumerate(cams):
        cnt = 0
        for j in range(i + 1, len(cams)):
            cb = cams[j]
            base = np.linalg.norm(ca["C"] - cb["C"])
            if base < min_base or base > max_base:
                continue
            ang = np.degrees(np.arccos(np.clip(ca["fwd"] @ cb["fwd"], -1, 1)))
            if ang > max_ang:
                continue
            pairs.append((i, j)); cnt += 1
            if cnt >= max_pairs:
                break
    return pairs


class UF:
    def __init__(self): self.p = {}
    def find(self, x):
        self.p.setdefault(x, x)
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]; x = self.p[x]
        return x
    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb: self.p[ra] = rb


def build_tracks(cams, feats, pairs, ratio, epi_t):
    matcher = cv2.BFMatcher(cv2.NORM_L2)
    uf = UF()
    n_raw = n_epi = 0
    for (i, j) in pairs:
        pa, da = feats[i]; pb, db = feats[j]
        if da is None or db is None or len(da) < 8 or len(db) < 8:
            continue
        mm = matcher.knnMatch(da.astype(np.float32), db.astype(np.float32), k=2)
        good = [(m.queryIdx, m.trainIdx) for m, s in mm if m.distance < ratio * s.distance]
        if not good:
            continue
        qa = pa[[g[0] for g in good]]; qb = pb[[g[1] for g in good]]
        F = fundamental(cams[i], cams[j])
        d = epi_dist(F, qa, qb)
        n_raw += len(good)
        for (qi, ti), dd in zip(good, d):
            if dd <= epi_t:
                uf.union((i, qi), (j, ti)); n_epi += 1
    # raccogli tracce: track_id -> {cam_idx: feat_pixel}
    tracks = {}
    for (ci, fi) in list(uf.p.keys()):
        r = uf.find((ci, fi))
        tracks.setdefault(r, {})
        # scarta tracce con 2 feature nella stessa immagine (ambiguo)
        if ci in tracks[r]:
            tracks[r][ci] = None
        else:
            tracks[r][ci] = feats[ci][0][fi]
    obs = []  # (cam_local_idx, px, py, track_id)
    valid_tracks = []
    for tid, d in tracks.items():
        clean = {c: p for c, p in d.items() if p is not None}
        if len(clean) >= 2:
            tn = len(valid_tracks)
            for c, p in clean.items():
                obs.append((c, p[0], p[1], tn))
            valid_tracks.append(tn)
    print(f"match raw {n_raw}, epi-ok {n_epi} ({100*n_epi/max(n_raw,1):.0f}%) | "
          f"tracce>=2: {len(valid_tracks)}, osservazioni: {len(obs)}")
    return obs, len(valid_tracks)


# ----------------------------- geometria piano -----------------------------

def triangulate_tracks(cams, obs, ntracks):
    """DLT a 2 viste per ogni traccia (init 3D)."""
    by_t = {}
    for (c, x, y, t) in obs:
        by_t.setdefault(t, []).append((c, x, y))
    X = np.zeros((ntracks, 3))
    ok = np.zeros(ntracks, bool)
    for t, ol in by_t.items():
        if len(ol) < 2:
            continue
        (c0, x0, y0), (c1, x1, y1) = ol[0], ol[1]
        Xh = cv2.triangulatePoints(cams[c0]["P"], cams[c1]["P"],
                                   np.array([[x0], [y0]]), np.array([[x1], [y1]]))
        if abs(Xh[3, 0]) < 1e-9:
            continue
        X[t] = (Xh[:3, 0] / Xh[3, 0]); ok[t] = True
    return X, ok


def fit_plane_ransac(X, normal_prior, iters=2000, thr=0.05):
    best_in, best = None, None
    n = len(X)
    rng = np.random.default_rng(0)
    for _ in range(iters):
        s = X[rng.choice(n, 3, replace=False)]
        v1, v2 = s[1] - s[0], s[2] - s[0]
        nn = np.cross(v1, v2)
        if np.linalg.norm(nn) < 1e-6:
            continue
        nn /= np.linalg.norm(nn)
        if abs(nn @ normal_prior) < 0.8:   # vincola ~ alla normale ARKit
            continue
        d = np.abs((X - s[0]) @ nn)
        inl = d < thr
        if best_in is None or inl.sum() > best_in.sum():
            best_in, best = inl, (s[0], nn)
    # raffina sugli inlier (SVD)
    p0, nn = best
    P = X[best_in]
    c = P.mean(0)
    _, _, Vt = np.linalg.svd(P - c)
    nn = Vt[2]
    if nn @ normal_prior < 0:
        nn = -nn
    return c, nn, best_in


# ----------------------------- bundle adjustment -----------------------------

def reproj(cams, cam_params, frame, pts2d, cam_idx, pt_idx, obs_xy):
    o, right, up, nrm = frame
    Xw = o + pts2d[:, 0:1] * right + pts2d[:, 1:2] * up   # (N,3) sul piano Z=0
    res = np.empty((len(cam_idx), 2))
    for k, (ci, pi) in enumerate(zip(cam_idx, pt_idx)):
        sx, sy, fs = cam_params[ci]
        c = cams[ci]
        xc = c["R_cv"] @ Xw[pi] + c["t_cv"]
        z = xc[2] if abs(xc[2]) > 1e-6 else 1e-6
        u = c["K"][0, 0] * fs * xc[0] / z + c["K"][0, 2] + sx
        v = c["K"][1, 1] * fs * xc[1] / z + c["K"][1, 2] + sy
        res[k] = (u - obs_xy[k, 0], v - obs_xy[k, 1])
    return res.ravel()


def residuals(params, ncam, npt, cams, frame, cam_idx, pt_idx, obs_xy):
    cam_params = params[:ncam * 3].reshape(ncam, 3)
    pts2d = params[ncam * 3:].reshape(npt, 2)
    return reproj(cams, cam_params, frame, pts2d, cam_idx, pt_idx, obs_xy)


def sparsity(ncam, npt, cam_idx, pt_idx):
    m = len(cam_idx) * 2
    n = ncam * 3 + npt * 2
    A = lil_matrix((m, n), dtype=int)
    i = np.arange(len(cam_idx))
    for s in range(3):
        A[2 * i, cam_idx * 3 + s] = 1
        A[2 * i + 1, cam_idx * 3 + s] = 1
    for s in range(2):
        A[2 * i, ncam * 3 + pt_idx * 2 + s] = 1
        A[2 * i + 1, ncam * 3 + pt_idx * 2 + s] = 1
    return A


def stats(r):
    e = np.linalg.norm(r.reshape(-1, 2), axis=1)
    return np.median(e), np.percentile(e, 90), e.mean()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--step", type=int, default=3)
    ap.add_argument("--max-pairs", type=int, default=6)
    ap.add_argument("--scale", type=float, default=0.5)
    ap.add_argument("--nfeat", type=int, default=3000)
    ap.add_argument("--ratio", type=float, default=0.8)
    ap.add_argument("--epi", type=float, default=2.0)
    ap.add_argument("--banda", type=float, default=0.06, help="m: spessore filo-muro tenuto")
    args = ap.parse_args()

    t0 = time.time()
    allcams = load_cams()
    cams = allcams[::args.step]
    print(f"camere usate: {len(cams)} (step {args.step})")

    feats = detect(cams, args.scale, args.nfeat)
    pairs = select_pairs(cams, args.max_pairs, 0.5, 4.0, 30.0)
    print(f"coppie selezionate: {len(pairs)}  ({time.time()-t0:.0f}s)")
    obs, ntracks = build_tracks(cams, feats, pairs, args.ratio, args.epi)
    if ntracks < 50:
        print("troppe poche tracce — alza step/coppie o abbassa epi"); return

    X, ok = triangulate_tracks(cams, obs, ntracks)
    nprior = np.mean([c["wall_n"] for c in cams], 0)
    nprior /= np.linalg.norm(nprior)
    o, nrm, inl = fit_plane_ransac(X[ok], nprior)
    print(f"piano: normale [{nrm[0]:.2f} {nrm[1]:.2f} {nrm[2]:.2f}]  inlier {inl.sum()}/{ok.sum()}")

    # frame del piano: up dal mondo (gravità ARKit = +Y), right ortogonale
    world_up = np.array([0, 1.0, 0])
    up = world_up - (world_up @ nrm) * nrm
    up /= np.linalg.norm(up)
    right = np.cross(up, nrm); right /= np.linalg.norm(right)
    frame = (o, right, up, nrm)

    # maschera parallasse: tieni le tracce entro ±banda dal piano (filo-muro)
    dist = (X - o) @ nrm
    keep = ok & (np.abs(dist) < args.banda)
    print(f"tracce sul filo-muro (±{args.banda} m): {keep.sum()}/{ok.sum()} "
          f"(scartate fuori-piano: {ok.sum()-keep.sum()})")

    # rimappa tracce tenute a indici densi
    remap = -np.ones(ntracks, int)
    remap[np.where(keep)[0]] = np.arange(keep.sum())
    npt = keep.sum()
    cam_idx, pt_idx, obs_xy = [], [], []
    for (c, x, y, t) in obs:
        if keep[t]:
            cam_idx.append(c); pt_idx.append(remap[t]); obs_xy.append((x, y))
    cam_idx = np.array(cam_idx); pt_idx = np.array(pt_idx); obs_xy = np.array(obs_xy)
    ncam = len(cams)

    # init: camere shift 0 focal 1; punti = proiezione del 3D triangolato sul piano
    x0_cam = np.zeros((ncam, 3)); x0_cam[:, 2] = 1.0
    Xk = X[keep]
    pts2d0 = np.stack([(Xk - o) @ right, (Xk - o) @ up], 1)
    x0 = np.hstack([x0_cam.ravel(), pts2d0.ravel()])

    r0 = residuals(x0, ncam, npt, cams, frame, cam_idx, pt_idx, obs_xy)
    m0, p90_0, _ = stats(r0)
    print(f"\nPRIMA del BA  (solo pose ARKit + punti sul piano): "
          f"mediano {m0:.2f} px, p90 {p90_0:.2f} px")

    A = sparsity(ncam, npt, cam_idx, pt_idx)
    res = least_squares(residuals, x0, jac_sparsity=A, method="trf",
                        loss="huber", f_scale=2.0, x_scale="jac",
                        ftol=1e-4, xtol=1e-4, max_nfev=60, verbose=1,
                        args=(ncam, npt, cams, frame, cam_idx, pt_idx, obs_xy))
    m1, p90_1, _ = stats(res.fun)
    print(f"\nDOPO il BA    (photo↔photo, OC-free, Huber): "
          f"mediano {m1:.2f} px, p90 {p90_1:.2f} px   [target v22: 1.86 / 6.17]")
    print(f"tempo totale {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
