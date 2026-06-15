#!/usr/bin/env python3
"""Proietta le foto ARKit sulla mesh Object Capture (frame OC, pose OC dirette).

NIENTE Umeyama, NIENTE RANSAC: le pose OC (`oc_poses.json`) sono già nel frame
della mesh OC, quindi ogni foto si proietta direttamente. Best-view per VERTICE
con occlusione (raycast Open3D). Output: PLY a colori-per-vertice.

Nota qualità: il per-vertice è "morbido" (1 colore per vertice). Per piena
risoluzione serve un bake nell'atlante UV (per-texel) — qui non implementato.

Proiezione pinhole OC (convenzione validata, vedi project_planes_photos.py):
    Pc = (G - C) @ R ; z = -Pc[2] ; u = fx*Pc0/z + cx ; v = fy*Pc1/z + cy

Uso:
    python project_photos_to_mesh.py \
        --mesh model_nobbox.obj --poses oc_poses_nobbox.json \
        --photos /path/al/fixtures/6cdcb8ff/photos --out model_nobbox_photo.ply

Dipendenze: pip install open3d opencv-python-headless numpy
"""
import argparse
import json
import os
import time

import cv2
import numpy as np
import open3d as o3d


def qR(w, x, y, z):
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def load_obj(path):
    """Parser minimale (ASSIMP fallisce su righe 'o'/'g' degli OBJ Object Capture)."""
    vs, fs = [], []
    for ln in open(path):
        if ln.startswith("v "):
            vs.append([float(a) for a in ln.split()[1:4]])
        elif ln.startswith("f "):
            idx = [int(t.split("/")[0]) - 1 for t in ln.split()[1:]]
            for i in range(1, len(idx) - 1):
                fs.append([idx[0], idx[i], idx[i + 1]])
    return np.asarray(vs, float), np.asarray(fs, np.int32)


def photo_path(photo_dir, k):
    for ext in ("jpg", "jpeg", "png", "JPG"):
        p = os.path.join(photo_dir, f"{int(k):04d}.{ext}")
        if os.path.exists(p):
            return p
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mesh", required=True, help="OBJ della mesh OC (frame OC)")
    ap.add_argument("--poses", required=True, help="oc_poses.json (translation/rotation_wxyz/intrinsics_fx_fy_cx_cy per foto)")
    ap.add_argument("--photos", required=True, help="cartella foto NNNN.jpg")
    ap.add_argument("--out", required=True, help="PLY di output (colori per vertice)")
    ap.add_argument("--occ-eps", type=float, default=0.012, help="tolleranza occlusione (frazione della diagonale mesh)")
    args = ap.parse_args()

    t0 = time.time()
    log = lambda m: print(f"[{time.time() - t0:6.1f}s] {m}", flush=True)

    V, Fa = load_obj(args.mesh)
    m = o3d.geometry.TriangleMesh(o3d.utility.Vector3dVector(V), o3d.utility.Vector3iVector(Fa))
    log(f"mesh: {len(V)} vertici, {len(Fa)} facce")
    diag = np.linalg.norm(V.max(0) - V.min(0))
    EPS = args.occ_eps * diag

    scene = o3d.t.geometry.RaycastingScene()
    scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(m))

    P = json.load(open(args.poses))
    keys = sorted((k for k in P if "translation" in P[k]), key=int)
    CAM = [(k, np.array(P[k]["translation"]), qR(*P[k]["rotation_wxyz"]), P[k]["intrinsics_fx_fy_cx_cy"]) for k in keys]
    log(f"camere: {len(CAM)}")

    best = np.full(len(V), -1e9, np.float32)
    col = np.zeros((len(V), 3), np.float32)
    src = np.full(len(V), -1, np.int32)
    used = 0
    for (k, C, R, (fx, fy, cx, cy)) in CAM:
        optical = R @ np.array([0, 0, -1.0])
        Pc = (V - C) @ R
        z = -Pc[..., 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            u = fx * Pc[..., 0] / z + cx
            v = fy * Pc[..., 1] / z + cy
        pth = photo_path(args.photos, k)
        if pth is None:
            continue
        img = cv2.imread(pth)
        if img is None:
            continue
        H, W = img.shape[:2]
        infront = (z > 0.02) & (u >= 1) & (v >= 1) & (u < W - 2) & (v < H - 2)
        if not infront.any():
            continue
        idx = np.where(infront)[0]
        dirs = (V[idx] - C)
        d = np.linalg.norm(dirs, axis=1)
        dirs = dirs / d[:, None]
        rays = o3d.core.Tensor(np.hstack([np.repeat(C[None, :], len(idx), 0), dirs]).astype(np.float32))
        hit = scene.cast_rays(rays)["t_hit"].numpy()
        visible = hit >= (d - EPS)
        idx = idx[visible]
        if len(idx) == 0:
            continue
        cosang = (optical @ (-(V[idx] - C).T / np.maximum(d[visible], 1e-6)))
        nx = (u[idx] - W * 0.5) / (W * 0.5)
        ny = (v[idx] - H * 0.5) / (H * 0.5)
        centrality = 1.0 - np.clip(np.sqrt(nx * nx + ny * ny), 0, 1.4) / 1.4
        dist = 1.0 / np.maximum(d[visible], 1e-3 * diag)
        score = (2.0 * centrality + 1.2 * np.clip(cosang, 0, 1) + 0.35 * dist / np.max(dist + 1e-9)).astype(np.float32)
        upd = score > best[idx]
        if not upd.any():
            continue
        sel = idx[upd]
        uu = u[sel].astype(np.float32).reshape(1, -1)
        vv = v[sel].astype(np.float32).reshape(1, -1)
        samp = cv2.remap(img, uu, vv, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)[0]
        col[sel] = samp[:, ::-1].astype(np.float32) / 255.0
        best[sel] = score[upd]
        src[sel] = int(k)
        used += 1

    cov = (src >= 0)
    log(f"copertura vertici: {100 * cov.mean():.1f}%  foto usate: {used}")
    col[~cov] = np.array([0.4, 0.4, 0.4])
    m.vertex_colors = o3d.utility.Vector3dVector(col.astype(np.float64))
    o3d.io.write_triangle_mesh(args.out, m, write_ascii=False)
    log(f"[OK] scritto {args.out}")


if __name__ == "__main__":
    main()
