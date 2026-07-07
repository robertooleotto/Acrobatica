#!/usr/bin/env python3
"""Genera un OBJ a gruppi-piano (formato NativePoseMeshViewer) dai muri verticali
dominanti di una mesh OC, NEL FRAME OC (stesso di pose e mesh). Serve per testare
il bake headless con tutto nello stesso frame (niente disallineamenti BCS).

Ogni piano = 1 quad (4 corner) con winding tale che la normale punta FUORI dal
muro. Uso:
    python -m scripts.oc_planes_to_obj --mesh model_nobbox.obj --out piani_oc.obj [--k 4]
"""
import argparse
import sys

import numpy as np

sys.path.insert(0, ".")
from app.services import ortho_bake as ob


def face_normals(V, F):
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    n = np.cross(b - a, c - a)
    ln = np.linalg.norm(n, axis=1)
    return n / np.maximum(ln, 1e-12)[:, None], 0.5 * ln, (a + b + c) / 3.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mesh", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--k", type=int, default=4, help="n. piani (muri) da estrarre")
    args = ap.parse_args()

    V, F = ob.load_obj(args.mesh)
    up = np.array([0.0, 1.0, 0.0])
    n, area, ctr = face_normals(V, F)
    meshc = V.mean(0)
    vertical = np.abs(n @ up) < 0.35
    idx = np.where(vertical)[0]
    no = n[idx].copy()
    outward = ((ctr[idx] - meshc) * no).sum(1) < 0
    no[outward] *= -1

    used = np.zeros(len(idx), bool)
    groups = []
    for _ in range(args.k):
        rem = np.where(~used)[0]
        if len(rem) == 0:
            break
        seed = rem[np.argmax(area[idx][rem])]
        nd = ob._unit(no[seed])
        same = (no @ nd > 0.6) & (~used)
        if same.sum() < 3:
            used[seed] = True
            continue
        used |= same
        pts = V[F[idx[same]].reshape(-1)]
        v = ob._unit(up - np.dot(up, nd) * nd)          # verticale nel piano
        u = ob._unit(np.cross(v, nd))                    # orizzontale
        o = pts.mean(0)
        du, dv = (pts - o) @ u, (pts - o) @ v
        umin, umax, vmin, vmax = du.min(), du.max(), dv.min(), dv.max()
        c0 = o + u * umin + v * vmin
        c1 = o + u * umax + v * vmin
        c2 = o + u * umax + v * vmax
        c3 = o + u * umin + v * vmax
        # winding: normale (c1-c0)x(c2-c0) deve puntare come nd (fuori dal muro)
        fn = np.cross(c1 - c0, c2 - c0)
        corners = [c0, c1, c2, c3] if np.dot(fn, nd) >= 0 else [c0, c3, c2, c1]
        w = umax - umin
        groups.append((f"plane_{len(groups)+1}_facciata", corners, w * (vmax - vmin)))

    groups.sort(key=lambda g: -g[2])
    with open(args.out, "w") as fh:
        fh.write("# piani nel FRAME OC (stesso di pose/mesh) — winding: normale fuori dal muro\n")
        fh.write("o oc_planes\n")
        vi = 1
        for name, corners, _ in groups:
            fh.write(f"g {name}\n")
            for c in corners:
                fh.write(f"v {c[0]:.6f} {c[1]:.6f} {c[2]:.6f}\n")
            fh.write(f"f {vi} {vi+1} {vi+2}\nf {vi} {vi+2} {vi+3}\n")
            vi += 4
    print(f"[OK] {len(groups)} piani scritti in {args.out}")


if __name__ == "__main__":
    main()
