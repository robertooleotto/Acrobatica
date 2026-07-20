#!/usr/bin/env python3
"""ENTRY-POINT UNICO della pipeline "slice-contours -> fused planes".
Dalla mesh (metrica, o OC + transform) e dai piani CGAL genera i piani fused in
metri reali, de-hardcoded e parametrico. Catena:

  build_slice_stack -> simplify_stack -> assign_slice_to_planes -> build_fused_planes

Uso:
  # mesh gia' in metri
  python run_fused_planes.py --mesh model_metric.obj --planes planes.json --out-dir OUT
  # mesh OC + transform OC->ARKit (applica la scala)
  python run_fused_planes.py --oc-mesh model_nobbox.obj --transform oc_to_arkit_transform.json \
        --planes planes.json --out-dir OUT

Esce: OUT/fused_planes.json (+ viewer.html) e OUT/detected_planes.json (schema editor).
"""
import argparse
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from assign_slice_to_planes import assign_segments, load_planes  # noqa: E402


def sh(cmd):
    print("  $", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True)


def scale_mesh(oc_mesh, scale, out_obj):
    """Mesh metrica = OC x scala (SOLO scala uniforme, niente rotazione): la Y
    dell'OC e' gia' verticale, e i piani CGAL (planes.json) vivono nello stesso
    frame OC scalato x scale. Applicare la rotazione OC->ARKit li disallineerebbe."""
    with open(oc_mesh) as fin, open(out_obj, "w") as fout:
        for line in fin:
            if line.startswith("v "):
                _, x, y, z = line.split()[:4]
                fout.write(f"v {float(x)*scale:.8f} {float(y)*scale:.8f} {float(z)*scale:.8f}\n")
            else:
                fout.write(line)
    return out_obj


def to_detected_planes(fused, oc_scale=1.0):
    """fused_planes.json -> schema DetectedPlane atteso dall'editor iOS.
    La geometria (corners/punto) viene riportata nel frame OC (÷ scala) per
    sovrapporsi alla mesh che l'editor scarica in unità OC; area_m2/w/h restano
    in METRI reali (per l'etichetta)."""
    s = oc_scale if oc_scale else 1.0
    out = []
    for p in fused["planes"]:
        out.append({
            "nome": p["nome"],
            "tipo": p.get("tipo", "fused-plane"),
            "punto": [v / s for v in p["punto"]],
            "normale": p["normale"],
            "corners": [[v / s for v in c] for c in p["corners"]],
            "area_m2": round(p["area_m2"], 2),
            "w": round(p["w"], 3),
            "h": round(p["h"], 3),
            "triangoli": [],   # piani sintetici: nessuna maschera triangoli
        })
    return {"engine": "slice_contours_fused", "planes": out,
            "source": fused.get("source", {})}


def pick_best_slice(stack_path):
    """Pick a stable lower-middle ring, away from ground clutter and roof setbacks."""
    stack = json.load(open(stack_path))
    ys = [s["y"] for s in stack["slices"]]
    ylo, yhi = min(ys), max(ys)
    target = ylo + 0.35 * (yhi - ylo)
    lengths = sorted(float(s.get("main_length", 0.0)) for s in stack["slices"])
    median_length = lengths[len(lengths) // 2] if lengths else 0.0
    best_score, best_i = None, 0
    for position, s in enumerate(stack["slices"]):
        if s.get("main_reg_pts", 0) < 4:
            continue
        if float(s.get("main_length", 0.0)) < median_length * 0.70:
            continue
        score = abs(float(s["y"]) - target)
        if best_score is None or score < best_score:
            best_score, best_i = score, position
    return best_i


def dominant_angle(planes_path):
    """Direction of the largest vertical CGAL facade in the horizontal plane."""
    planes = json.load(open(planes_path)).get("planes", [])
    candidates = [p for p in planes if abs(float(p["normale"][1])) <= 0.35]
    if not candidates:
        raise RuntimeError("CGAL non ha trovato piani verticali da cui ricavare l'orientamento")
    main = max(candidates, key=lambda p: float(p.get("area_m2", 0.0)))
    nx, _, nz = main["normale"]
    return math.degrees(math.atan2(float(nx), -float(nz))) % 180.0


def candidate_is_persistent(slice_count, total_slices, y_span, support_length,
                            min_ratio=0.15, min_count=3,
                            min_y_span=1.5, min_support_length=8.0):
    required = max(min_count, math.ceil(total_slices * min_ratio))
    return (slice_count >= required and y_span >= min_y_span
            and support_length >= min_support_length)


def validate_candidates_with_slices(stack_path, planes_path, output_path,
                                    max_dist=2.5, max_angle=14.0):
    """Keep planes that repeatedly explain the perimeter, regardless of label."""
    stack = json.load(open(stack_path))
    document = json.load(open(planes_path))
    planes = load_planes(planes_path, True)
    stats = {
        plane["id"]: {"slices": set(), "ys": [], "length": 0.0}
        for plane in planes
    }
    for slice_index, slice_data in enumerate(stack.get("slices", [])):
        for segment in assign_segments(slice_data, planes, max_dist, max_angle):
            plane_id = segment.get("plane_id")
            if plane_id is None:
                continue
            item = stats[plane_id]
            item["slices"].add(slice_index)
            item["ys"].append(float(slice_data["y"]))
            item["length"] += float(segment.get("length", 0.0))

    total_slices = len(stack.get("slices", []))
    accepted = set()
    summary = {}
    for plane_id, item in stats.items():
        y_span = (max(item["ys"]) - min(item["ys"])) if item["ys"] else 0.0
        slice_count = len(item["slices"])
        keep = candidate_is_persistent(
            slice_count, total_slices, y_span, item["length"])
        summary[str(plane_id)] = {
            "slices": slice_count,
            "y_span": y_span,
            "support_length": item["length"],
            "accepted": keep,
        }
        if keep:
            accepted.add(plane_id)

    validated = dict(document)
    validated["planes"] = [
        plane for plane in document.get("planes", [])
        if plane.get("id") in accepted
    ]
    validated["slice_validation"] = summary
    with open(output_path, "w") as output:
        json.dump(validated, output)
    if not validated["planes"]:
        raise RuntimeError("Nessun candidato planare persiste lungo le fette")
    return validated


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--mesh", help="mesh gia' in metri (OBJ)")
    g.add_argument("--oc-mesh", help="mesh OC grezza (OBJ), richiede --transform o --scale")
    ap.add_argument("--transform", help="oc_to_arkit_transform.json (usa il campo scale)")
    ap.add_argument("--scale", type=float, help="scala OC->metri (alternativa a --transform)")
    ap.add_argument("--planes", help="piani CGAL (planes.json); se assente li genera")
    ap.add_argument("--out-dir", required=True)
    # parametri catena (default = i valori validati a mano)
    ap.add_argument("--step", type=float, default=0.3)
    ap.add_argument("--angle", default="auto", help="direzione principale in gradi, o 'auto'")
    ap.add_argument("--line-tolerance", type=float, default=0.75)
    ap.add_argument("--min-edge", type=float, default=0.75)
    ap.add_argument("--slice-index", default="auto", help="indice fetta o 'auto'")
    ap.add_argument("--max-dist", type=float, default=2.5)
    ap.add_argument("--max-angle", type=float, default=14.0)
    args = ap.parse_args()

    out = args.out_dir
    os.makedirs(out, exist_ok=True)
    py = sys.executable

    # scala OC->metri
    if args.scale:
        scale = args.scale
    elif args.transform:
        scale = float(json.load(open(args.transform))["scale"])
    else:
        scale = 1.0
    os.environ["ACRO_OC_SCALE"] = repr(scale)   # visto da assign/build_fused

    # 0) mesh in metri (OC x scala uniforme) + eventuale generazione piani
    oc_obj = args.oc_mesh or args.mesh
    if args.oc_mesh:
        mesh = scale_mesh(args.oc_mesh, scale, os.path.join(out, "mesh_metric.obj"))
    else:
        mesh = args.mesh

    planes_json = args.planes
    if not planes_json:
        planes_json = os.path.join(out, "cgal_planes.json")
        print("[0/4] build_cgal_planes (auto)")
        sh([py, os.path.join(HERE, "build_cgal_planes.py"), oc_obj, planes_json])
    args_planes = planes_json
    angle = dominant_angle(args_planes) if str(args.angle).lower() == "auto" else float(args.angle)
    print(f"[auto] direzione principale = {angle:.2f} deg")

    stack_before = os.path.join(out, "stack_before.json")
    stack = os.path.join(out, "slice_stack.json")
    fusion = os.path.join(out, "fusion.json")

    print("[1/4] build_slice_stack")
    sh([py, os.path.join(HERE, "build_slice_stack.py"), mesh, stack_before,
        "--step", str(args.step), "--angle", str(angle)])

    print("[2/4] simplify_stack")
    sh([py, os.path.join(HERE, "simplify_stack.py"), stack_before, stack,
        "--source-key", "raw", "--angle-deg", str(angle),
        "--line-tolerance", str(args.line_tolerance), "--min-edge", str(args.min_edge)])

    validated_planes = os.path.join(out, "validated_cgal_planes.json")
    validated = validate_candidates_with_slices(
        stack, args_planes, validated_planes,
        max_dist=args.max_dist, max_angle=args.max_angle)
    print(f"[validate] candidati persistenti = {len(validated['planes'])}")
    args_planes = validated_planes

    # (a) scelta fetta: auto o indice esplicito
    if str(args.slice_index) == "auto":
        slice_index = pick_best_slice(stack)
        print(f"[auto] fetta scelta = {slice_index}")
    else:
        slice_index = int(args.slice_index)

    print("[3/4] assign_slice_to_planes")
    sh([py, os.path.join(HERE, "assign_slice_to_planes.py"), stack, args_planes, fusion,
        "--slice-index", str(slice_index),
        "--max-dist", str(args.max_dist), "--max-angle", str(args.max_angle)])

    print("[4/4] build_fused_planes")
    sh([py, os.path.join(HERE, "build_fused_planes.py"),
        "--stack", stack, "--fusion", fusion, "--planes", args_planes, "--out-dir", out])

    fused = json.load(open(os.path.join(out, "fused_planes.json")))
    detected = to_detected_planes(fused, oc_scale=scale)
    with open(os.path.join(out, "detected_planes.json"), "w") as f:
        json.dump(detected, f)
    tot = sum(p["area_m2"] for p in detected["planes"])
    print(f"\nOK: {len(detected['planes'])} piani fused, area totale {tot:.0f} m²")
    print(f"    -> {out}/fused_planes.json + detected_planes.json")


if __name__ == "__main__":
    main()
