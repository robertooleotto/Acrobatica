#!/usr/bin/env python3
"""Engine detector 'fused' per il backend: incapsula la pipeline slice-contours
-> fused planes. Dalla mesh OC genera
allinea una copia nel frame ARKit, screma i perimetri persistenti e restituisce
i piani nel frame OC originale con area in m² reali.

Uso: python -m scripts.detect_planes_fused mesh.obj --out /tmp/piani --scale 6.0927
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

_BACKEND = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_RUN = os.path.join(_BACKEND, "fused_planes", "run.py")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mesh")
    ap.add_argument("--out", required=True, help="base output (scrive <out>.json)")
    ap.add_argument("--scale", type=float, required=True, help="scala metri per unita mesh")
    ap.add_argument("--transform", help="similarita OC->ARKit completa")
    ap.add_argument("--up", type=float, nargs=3, default=[0.0, 1.0, 0.0])  # ignorato
    ap.add_argument("--slice-index", default="auto")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory(prefix="fused_") as wd:
        command = [sys.executable, _RUN, "--oc-mesh", args.mesh,
                   "--slice-index", str(args.slice_index), "--out-dir", wd]
        if args.transform:
            command += ["--transform", args.transform]
        else:
            command += ["--scale", str(args.scale)]
        subprocess.run(command, check=True)
        det = json.load(open(os.path.join(wd, "detected_planes.json")))

    doc = {"up": args.up, "engine": "fused", "planes": det["planes"],
           "source": det.get("source", {})}
    with open(args.out + ".json", "w") as f:
        json.dump(doc, f)
    print(f"fused: {len(doc['planes'])} piani -> {args.out}.json")


if __name__ == "__main__":
    main()
