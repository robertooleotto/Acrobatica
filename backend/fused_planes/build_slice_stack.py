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
import math
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
        command = [slicer, mesh, f"{y:.6f}", out, str(max_offset), str(min_length)]
        if angle is not None:
            command.append(str(angle))
        subprocess.run(command, check=True, capture_output=True)
        d = json.load(open(out))
    finally:
        os.unlink(out)
    contours = d.get("contours", [])
    return contours


def slice_batch(slicer, mesh, ys, angle, max_offset, min_length):
    """Slice every height after loading the mesh once in the native process."""
    heights_path = output_path = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as hf:
            heights_path = hf.name
            hf.write("\n".join(f"{y:.6f}" for y in ys))
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as of:
            output_path = of.name

        command = [
            slicer,
            mesh,
            "--batch",
            heights_path,
            output_path,
            str(max_offset),
            str(min_length),
        ]
        if angle is not None:
            command.append(str(angle))
        subprocess.run(
            command,
            check=True,
            capture_output=True,
        )
        with open(output_path) as f:
            payload = json.load(f)
        slices = payload.get("slices", [])
        if len(slices) != len(ys):
            raise ValueError(f"batch slicer: attese {len(ys)} fette, ricevute {len(slices)}")
        return [(float(item["y"]), item.get("contours", [])) for item in slices]
    finally:
        for path in (heights_path, output_path):
            if path and os.path.exists(path):
                os.unlink(path)


def estimate_global_angle(results, min_edge=0.30):
    """Estimate orthogonal building axes from per-contour CGAL regularization."""
    cosine_sum = sine_sum = total = 0.0
    for _, contours in results:
        if not contours:
            continue
        main = max(contours, key=lambda contour: float(contour.get("length", 0.0)))
        points = main.get("regularized") or main.get("raw") or []
        for a, b in zip(points, points[1:]):
            dx = float(b[0]) - float(a[0])
            dz = float(b[2]) - float(a[2])
            length = math.hypot(dx, dz)
            if length < min_edge:
                continue
            angle = math.atan2(dz, dx)
            weight = min(length, 5.0)
            # Fourfold circular mean: equivalent directions repeat every 90°.
            cosine_sum += weight * math.cos(4.0 * angle)
            sine_sum += weight * math.sin(4.0 * angle)
            total += weight
    if total <= 1e-9 or math.hypot(cosine_sum, sine_sum) / total < 0.15:
        raise ValueError("perimetro senza orientamento principale stabile")
    return math.degrees(math.atan2(sine_sum, cosine_sum) / 4.0) % 90.0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mesh")
    ap.add_argument("out")
    ap.add_argument("--step", type=float, default=0.3)
    ap.add_argument("--angle", default="auto", help="gradi oppure 'auto'")
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

    requested_angle = None if str(args.angle).lower() == "auto" else float(args.angle)
    try:
        results = slice_batch(
            args.slicer,
            args.mesh,
            ys,
            requested_angle,
            args.max_offset,
            args.min_length,
        )
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ValueError) as exc:
        # Keep compatibility with older locally installed slicers during upgrades.
        print(f"batch slicer non disponibile ({exc}); uso modalita per-fetta")

        def work(iy):
            i, yy = iy
            cs = slice_at(
                args.slicer, args.mesh, yy, requested_angle,
                args.max_offset, args.min_length)
            return i, yy, cs

        results = [None] * len(ys)
        with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
            for i, yy, cs in ex.map(work, enumerate(ys)):
                results[i] = (yy, cs)

    angle = requested_angle if requested_angle is not None else estimate_global_angle(results)
    if requested_angle is None:
        print(f"orientamento dal solo perimetro: {angle:.2f} deg")

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
        "global_angle_deg": angle,
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
