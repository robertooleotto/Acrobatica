#!/usr/bin/env python3
"""ANELLO MANCANTE della pipeline: dalla mesh (metrica) genera lo stack di fette
grezze, equivalente a slice_stack_before_linear.json. Guida il binario CGAL
slicer su tutta l'altezza (step_m), assembla i contorni per fetta e vi allega la
mesh. Poi lo stack va passato a simplify_stack.py.

Uso:  python build_slice_stack.py mesh_metric.obj out_stack.json
        [--step 0.3] [--angle 28] [--max-offset 0.20] [--min-length 0.30]
        [--slicer <path binario>] [--jobs 4]
"""
import argparse
import concurrent.futures as cf
import json
import os
import subprocess
import tempfile

SLICER_DEFAULT = os.environ.get("ACRO_SLICER_BIN", "/usr/local/bin/acro-slice-contours")


def load_obj_flat(path):
    """OBJ -> (vertices flat [x,y,z,...], faces flat [i,j,k,...] 0-based, bbox)."""
    verts, faces = [], []
    ymin = ymax = None
    with open(path) as f:
        for line in f:
            if line.startswith("v "):
                _, x, y, z = line.split()[:4]
                x, y, z = float(x), float(y), float(z)
                verts.extend((x, y, z))
                ymin = y if ymin is None else min(ymin, y)
                ymax = y if ymax is None else max(ymax, y)
            elif line.startswith("f "):
                idx = [int(t.split("/")[0]) - 1 for t in line.split()[1:]]
                for k in range(1, len(idx) - 1):        # triangola i poligoni
                    faces.extend((idx[0], idx[k], idx[k + 1]))
    return verts, faces, ymin, ymax


def slice_at(slicer, mesh, y, angle, max_offset, min_length):
    with tempfile.NamedTemporaryFile("r", suffix=".json", delete=False) as tf:
        out = tf.name
    try:
        subprocess.run([slicer, mesh, f"{y:.6f}", out, str(max_offset), str(min_length),
                        str(angle)], check=True, capture_output=True)
        d = json.load(open(out))
    finally:
        os.unlink(out)
    contours = d.get("contours", [])
    return contours


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mesh")
    ap.add_argument("out")
    ap.add_argument("--step", type=float, default=0.3)
    ap.add_argument("--angle", type=float, default=28.0)
    ap.add_argument("--max-offset", type=float, default=0.20)
    ap.add_argument("--min-length", type=float, default=0.30)
    ap.add_argument("--slicer", default=SLICER_DEFAULT)
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("ACRO_SLICE_JOBS", "2")))
    args = ap.parse_args()

    verts, faces, ymin, ymax = load_obj_flat(args.mesh)
    print(f"mesh: {len(verts)//3} vertici, {len(faces)//3} facce, y=[{ymin:.2f}..{ymax:.2f}]")

    ys, y = [], ymin + args.step * 0.5
    while y < ymax:
        ys.append(round(y, 6)); y += args.step

    def work(iy):
        i, yy = iy
        cs = slice_at(args.slicer, args.mesh, yy, args.angle, args.max_offset, args.min_length)
        return i, yy, cs

    results = [None] * len(ys)
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for i, yy, cs in ex.map(work, enumerate(ys)):
            results[i] = (yy, cs)

    slices = []
    for i, (yy, cs) in enumerate(results):
        if not cs:
            continue
        main_c = max(cs, key=lambda c: c["length"])
        slices.append({
            "index": i,
            "y": yy,
            "contours": cs,
            "main_length": main_c["length"],
            "main_raw_pts": len(main_c.get("raw", [])),
            "main_reg_pts": len(main_c.get("regularized", [])),
        })

    stack = {
        "step_m": args.step,
        "scale": "metric",
        "global_angle_deg": args.angle,
        "ymin": ymin,
        "ymax": ymax,
        "mesh": {"vertices": verts, "faces": faces},
        "slices": slices,
    }
    with open(args.out, "w") as f:
        json.dump(stack, f, separators=(",", ":"))
    print(f"stack: {len(slices)} fette con contorni -> {args.out}")


if __name__ == "__main__":
    main()
