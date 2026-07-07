#!/usr/bin/env python3
"""Ponte: piani dell'editor (planes.json, schema acro.planes/v1) → OBJ a gruppi
nel frame OC, il formato che il NativePoseMeshViewer headless sa bakare.

Per ogni piano usa i suoi `triangoli` sulla mesh (frame OC) per calcolare
l'estensione reale del rettangolo, gli assi u (orizzontale) / v (verticale=gravità
da piano_base.up), e scrive un quad (4 corner) con winding tale che la normale
punti FUORI dal muro. Tutto resta nel frame OC (stesso di pose e mesh).

Uso:
    python -m scripts.planes_json_to_obj --planes planes.json \
        --mesh model_nobbox.obj --out piani_oc.obj
"""
import argparse
import json
import sys

import numpy as np

sys.path.insert(0, ".")
from app.services import ortho_bake as ob


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--planes", required=True, help="planes.json (schema acro.planes/v1)")
    ap.add_argument("--mesh", required=True, help="mesh OC (frame OC, come nell'editor)")
    ap.add_argument("--out", required=True, help="OBJ a gruppi-piano di output")
    args = ap.parse_args()

    doc = json.load(open(args.planes))
    planes = doc.get("planes", [])
    V, F = ob.load_obj(args.mesh)
    pb = doc.get("piano_base") or {}
    up = ob._unit(np.asarray(pb.get("up", [0.0, 1.0, 0.0]), float))

    groups = []
    for i, pl in enumerate(planes, 1):
        pf = ob.plane_frame(pl, up, V, F, texel_m=0.01)  # texel irrilevante: servono i corner
        if pf is None:
            print(f"  piano {i} ({pl.get('nome')}): degenere/senza triangoli → salto")
            continue
        o, u, v = pf.origin, pf.u, pf.v
        w, h = pf.width_m, pf.height_m
        c0 = o
        c1 = o + u * w
        c2 = o + u * w + v * h
        c3 = o + v * h
        # winding: la normale del quad deve puntare come la normale del piano (fuori dal muro)
        n = ob._unit(np.asarray(pl["normale"], float))
        fn = np.cross(c1 - c0, c2 - c0)
        corners = [c0, c1, c2, c3] if np.dot(fn, n) >= 0 else [c0, c3, c2, c1]
        nome = pl.get("nome") or pl.get("tipo") or f"piano{i}"
        tipo = pl.get("tipo", "facciata")
        groups.append((f"plane_{i}_{tipo}", corners))

    with open(args.out, "w") as fh:
        fh.write("# piani editor→viewer, frame OC (winding: normale fuori dal muro)\n")
        fh.write("o editor_planes\n")
        vi = 1
        for name, corners in groups:
            fh.write(f"g {name}\n")
            for c in corners:
                fh.write(f"v {c[0]:.6f} {c[1]:.6f} {c[2]:.6f}\n")
            fh.write(f"f {vi} {vi+1} {vi+2}\nf {vi} {vi+2} {vi+3}\n")
            vi += 4
    print(f"[OK] {len(groups)} piani scritti in {args.out}")


if __name__ == "__main__":
    main()
