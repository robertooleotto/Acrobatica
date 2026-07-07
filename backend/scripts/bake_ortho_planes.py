#!/usr/bin/env python3
"""Test locale del bake ortofoto per piano (app.services.ortho_bake).

Se non passi --planes, genera piani di test dai muri verticali dominanti della
mesh (auto), così si valida il baker senza dipendere dall'editor. In produzione
i piani arrivano dall'editor (schema acro.planes/v1, out/planes.json su storage).

Uso:
    python -m scripts.bake_ortho_planes \
        --mesh .../model_nobbox.obj --poses .../oc_poses_nobbox.json \
        --photos .../photos --out /tmp/bake_test [--planes planes.json] \
        [--texel-mm 12] [--auto-planes 4] [--occlusion]
"""
import argparse
import json
import sys

import numpy as np

sys.path.insert(0, ".")
from app.services import ortho_bake as ob


def face_normals(V, F):
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    n = np.cross(b - a, c - a)
    ln = np.linalg.norm(n, axis=1)
    area = 0.5 * ln
    n = n / np.maximum(ln, 1e-12)[:, None]
    ctr = (a + b + c) / 3.0
    return n, area, ctr


def auto_planes(V, F, up, k=4):
    """Genera fino a k piani verticali dominanti (per direzione di normale)."""
    n, area, ctr = face_normals(V, F)
    up = up / np.linalg.norm(up)
    vertical = np.abs(n @ up) < 0.35            # muri (normale ~ orizzontale)
    idx = np.where(vertical)[0]
    if len(idx) == 0:
        return []
    # orienta ogni normale verso l'esterno (via centroide mesh) e raggruppa per direzione
    meshc = V.mean(0)
    no = n[idx].copy()
    outward = ((ctr[idx] - meshc) * no).sum(1) < 0
    no[outward] *= -1
    used = np.zeros(len(idx), bool)
    planes = []
    for _ in range(k):
        rem = np.where(~used)[0]
        if len(rem) == 0:
            break
        # semina sulla faccia rimanente con più area, poi raccogli le complanari
        seed = rem[np.argmax(area[idx][rem])]
        nd = no[seed]
        same = (no @ nd > 0.6) & (~used)
        if same.sum() == 0:
            used[seed] = True
            continue
        used |= same
        tris = idx[same].tolist()
        pts = V[F[idx[same]].reshape(-1)]
        planes.append({
            "id": len(planes), "nome": f"muro{len(planes)+1}", "tipo": "facciata",
            "priorita": 0, "punto": pts.mean(0).tolist(), "normale": nd.tolist(),
            "n_triangoli": len(tris), "triangoli": tris,
        })
    # dal più grande al più piccolo
    planes.sort(key=lambda p: -p["n_triangoli"])
    return planes


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mesh", required=True)
    ap.add_argument("--poses", required=True)
    ap.add_argument("--photos", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--planes", help="documento piani (schema acro.planes/v1)")
    ap.add_argument("--auto-planes", type=int, default=4, help="n. piani auto se --planes assente")
    ap.add_argument("--texel-mm", type=float, default=12.0)
    ap.add_argument("--max-photos", type=int, default=80)
    ap.add_argument("--occlusion", action="store_true")
    args = ap.parse_args()

    poses = json.load(open(args.poses))
    if args.planes:
        doc = json.load(open(args.planes))
    else:
        V, F = ob.load_obj(args.mesh)
        up = np.array([0.0, 1.0, 0.0])
        pls = auto_planes(V, F, up, k=args.auto_planes)
        doc = {"schema": "acro.planes/v1", "versione": 1, "stato": "auto",
               "piano_base": {"origine": V.mean(0).tolist(), "normale": [0, 0, 1],
                              "right": [1, 0, 0], "up": up.tolist()},
               "planes": pls}
        print(f"[auto] {len(pls)} piani generati dai muri verticali")

    res = ob.bake_planes(args.mesh, poses, args.photos, doc, args.out,
                         texel_mm=args.texel_mm, max_photos=args.max_photos,
                         occlusion=args.occlusion)
    print(json.dumps(res, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
