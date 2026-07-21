#!/usr/bin/env python3
"""ENTRY-POINT UNICO della pipeline "perimetri persistenti -> piani".
Dalla mesh (metrica, o OC + transform temporaneo) genera piani in metri reali,
senza dipendere dall'orientamento scelto da Object Capture. Catena:

  build_slice_stack -> simplify_stack -> multi-slice open-surface reconstruction

The legacy single-slice fusion remains available only for comparison.

Uso:
  # mesh gia' in metri
  python run_fused_planes.py --mesh model_metric.obj --planes planes.json --out-dir OUT
  # mesh OC + transform OC->ARKit (solo frame temporaneo di analisi)
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

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from assign_slice_to_planes import assign_segments, load_planes  # noqa: E402
from analysis_frame import inverse_normal, inverse_point, load_similarity  # noqa: E402


def sh(cmd):
    print("  $", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True)


def transform_mesh(oc_mesh, scale, out_obj, rotation=None, translation=None):
    """Write a metric analysis copy without changing the source OC mesh."""
    rotation = np.eye(3) if rotation is None else np.asarray(rotation, dtype=float)
    translation = (np.zeros(3) if translation is None
                   else np.asarray(translation, dtype=float))
    with open(oc_mesh) as fin, open(out_obj, "w") as fout:
        for line in fin:
            if line.startswith("v "):
                _, x, y, z = line.split()[:4]
                point = scale * (rotation @ np.asarray(
                    [float(x), float(y), float(z)])) + translation
                fout.write(f"v {point[0]:.8f} {point[1]:.8f} {point[2]:.8f}\n")
            elif line.startswith("vn "):
                _, x, y, z = line.split()[:4]
                normal = rotation @ np.asarray([float(x), float(y), float(z)])
                fout.write(f"vn {normal[0]:.8f} {normal[1]:.8f} {normal[2]:.8f}\n")
            else:
                fout.write(line)
    return out_obj


def scale_mesh(oc_mesh, scale, out_obj):
    """Backward-compatible scale-only analysis copy."""
    return transform_mesh(oc_mesh, scale, out_obj)


def to_detected_planes(fused, oc_scale=1.0, analysis_similarity=None):
    """fused_planes.json -> schema DetectedPlane atteso dall'editor iOS.
    La geometria viene riportata nel frame OC con la similarita inversa per
    sovrapporsi alla mesh originale; area_m2/w/h restano in metri reali."""
    s = oc_scale if oc_scale else 1.0
    if analysis_similarity is not None:
        s, rotation, translation = analysis_similarity
    out = []
    for p in fused["planes"]:
        if analysis_similarity is not None:
            point = inverse_point(p["punto"], s, rotation, translation)
            corners = [inverse_point(corner, s, rotation, translation)
                       for corner in p["corners"]]
            normal = inverse_normal(p["normale"], rotation)
        else:
            point = [v / s for v in p["punto"]]
            corners = [[v / s for v in corner] for corner in p["corners"]]
            normal = p["normale"]
        out.append({
            "nome": p["nome"],
            "tipo": p.get("tipo", "fused-plane"),
            "punto": point,
            "normale": normal,
            "corners": corners,
            "area_m2": round(p["area_m2"], 2),
            "w": round(p["w"], 3),
            "h": round(p["h"], 3),
            "triangoli": [],   # piani sintetici: nessuna maschera triangoli
        })
    return {"engine": "slice_contours_fused", "planes": out,
            "source": fused.get("source", {})}


def pick_best_supported_slice(stack_path, planes_path, max_dist=0.65, max_angle=5.0):
    """Choose the ring explaining the most persistent perimeter candidates."""
    stack = json.load(open(stack_path))
    planes = load_planes(planes_path, True)
    best = None
    for position, slice_data in enumerate(stack.get("slices", [])):
        segments = assign_segments(slice_data, planes, max_dist, max_angle)
        assigned = [segment for segment in segments if segment.get("plane_id") is not None]
        plane_ids = {segment["plane_id"] for segment in assigned}
        support = sum(float(segment.get("length", 0.0)) for segment in assigned)
        fragmentation = len(assigned) - len(plane_ids)
        unassigned = len(segments) - len(assigned)
        score = (support + len(plane_ids) * 5.0
                 - fragmentation * 4.0 - unassigned * 2.0)
        candidate = (score, len(plane_ids), support, -position)
        if best is None or candidate > best[0]:
            best = (candidate, position)
    if best is None or best[0][1] < 2:
        raise RuntimeError("Nessuna fetta rappresenta il perimetro persistente")
    return best[1]


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
                                    max_dist=2.5, max_angle=18.0):
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
    ap.add_argument("--transform", help="similarita OC->ARKit usata solo nel frame di analisi")
    ap.add_argument("--scale", type=float, help="scala OC->metri (alternativa a --transform)")
    ap.add_argument("--planes", help="piani CGAL (planes.json); se assente li genera")
    ap.add_argument("--candidate-source", choices=("perimeter", "cgal"),
                    default="perimeter")
    ap.add_argument("--out-dir", required=True)
    # parametri catena (default = i valori validati a mano)
    ap.add_argument("--step", type=float, default=0.3)
    ap.add_argument("--angle", default="auto", help="direzione principale in gradi, o 'auto'")
    ap.add_argument("--line-tolerance", type=float, default=0.0)
    ap.add_argument("--min-edge", type=float, default=0.0)
    ap.add_argument("--slice-index", default="auto", help="indice fetta o 'auto'")
    ap.add_argument("--max-dist", type=float, default=2.5)
    ap.add_argument("--max-angle", type=float, default=18.0)
    ap.add_argument("--perimeter-max-dist", type=float, default=0.65)
    ap.add_argument("--perimeter-max-angle", type=float, default=5.0)
    ap.add_argument("--reconstruction", choices=("multi-slice", "single-slice"),
                    default="multi-slice")
    args = ap.parse_args()

    out = args.out_dir
    os.makedirs(out, exist_ok=True)
    py = sys.executable

    # scala OC->metri
    analysis_similarity = None
    if args.transform:
        analysis_similarity = load_similarity(args.transform)
        scale, rotation, translation = analysis_similarity
    elif args.scale:
        scale = args.scale
    else:
        scale = 1.0
    os.environ["ACRO_OC_SCALE"] = repr(scale)   # visto da assign/build_fused

    oc_obj = args.oc_mesh or args.mesh
    if args.oc_mesh:
        if analysis_similarity is not None:
            mesh = transform_mesh(
                oc_obj, scale, os.path.join(out, "mesh_metric.obj"),
                rotation, translation)
        else:
            mesh = scale_mesh(oc_obj, scale, os.path.join(out, "mesh_metric.obj"))
    else:
        mesh = oc_obj

    candidate_source = "cgal" if args.planes else args.candidate_source
    args_planes = args.planes
    if args.reconstruction == "multi-slice" and not args_planes:
        args_planes = os.path.join(out, "cgal_support_planes.json")
        print("[0/5] build_cgal_planes (supporto 3D)")
        # Region growing and slices must see the exact same metric geometry.
        sh([py, os.path.join(HERE, "build_cgal_planes.py"), mesh, args_planes,
            "--metric", "--support-only"])
        candidate_source = "cgal+perimeter"
    elif candidate_source == "cgal" and not args_planes:
        args_planes = os.path.join(out, "cgal_planes.json")
        print("[0/5] build_cgal_planes")
        sh([py, os.path.join(HERE, "build_cgal_planes.py"), oc_obj, args_planes])
    if candidate_source == "cgal" and args.reconstruction == "single-slice":
        angle = (dominant_angle(args_planes)
                 if str(args.angle).lower() == "auto" else float(args.angle))
        slice_angle = str(angle)
    else:
        slice_angle = str(args.angle)

    stack_before = os.path.join(out, "stack_before.json")
    stack = os.path.join(out, "slice_stack.json")
    fusion = os.path.join(out, "fusion.json")

    print("[1/5] build_slice_stack")
    sh([py, os.path.join(HERE, "build_slice_stack.py"), mesh, stack_before,
        "--step", str(args.step), "--angle", slice_angle])
    angle = float(json.load(open(stack_before))["global_angle_deg"])
    print(f"[perimeter] direzione locale = {angle:.2f} deg")

    print("[2/5] simplify_stack")
    simplify_command = [
        py, os.path.join(HERE, "simplify_stack.py"), stack_before, stack,
        "--source-key", "raw",
    ]
    if args.line_tolerance > 0:
        simplify_command.extend([
            "--angle-deg", str(angle),
            "--line-tolerance", str(args.line_tolerance),
            "--min-edge", str(args.min_edge),
        ])
    sh(simplify_command)

    if args.reconstruction == "multi-slice":
        print("[3/5] reconstruct_open_surface (regioni 3D + tutte le fette)")
        sh([py, os.path.join(HERE, "reconstruct_open_surface.py"),
            "--stack", stack, "--candidates", args_planes, "--out-dir", out])
        fused = json.load(open(os.path.join(out, "fused_planes.json")))
        fused.setdefault("source", {})["candidate_source"] = candidate_source
        fused["source"]["analysis_frame"] = "arkit" if analysis_similarity else "scaled_oc"
        detected = to_detected_planes(
            fused, oc_scale=scale, analysis_similarity=analysis_similarity)
        with open(os.path.join(out, "detected_planes.json"), "w") as f:
            json.dump(detected, f)
        total = sum(p["area_m2"] for p in detected["planes"])
        print(f"\nOK: {len(detected['planes'])} piani multi-slice, area totale {total:.0f} m²")
        print(f"    -> {out}/fused_planes.json + detected_planes.json")
        return

    if candidate_source == "perimeter":
        args_planes = os.path.join(out, "perimeter_planes.json")
        print("[3/5] build_perimeter_planes")
        sh([py, os.path.join(HERE, "build_perimeter_planes.py"), stack, args_planes,
            "--angle", str(angle)])
        assignment_dist = args.perimeter_max_dist
        assignment_angle = args.perimeter_max_angle
    else:
        validated_planes = os.path.join(out, "validated_cgal_planes.json")
        validated = validate_candidates_with_slices(
            stack, args_planes, validated_planes,
            max_dist=args.max_dist, max_angle=args.max_angle)
        print(f"[validate] candidati persistenti = {len(validated['planes'])}")
        args_planes = validated_planes
        assignment_dist = args.max_dist
        assignment_angle = args.max_angle

    # Legacy comparison: output topology comes from one selected slice.
    if str(args.slice_index) == "auto":
        slice_index = (pick_best_supported_slice(
            stack, args_planes, assignment_dist, assignment_angle)
            if candidate_source == "perimeter" else pick_best_slice(stack))
        print(f"[auto] fetta scelta = {slice_index}")
    else:
        slice_index = int(args.slice_index)

    print("[4/5] assign_slice_to_planes")
    sh([py, os.path.join(HERE, "assign_slice_to_planes.py"), stack, args_planes, fusion,
        "--slice-index", str(slice_index),
        "--max-dist", str(assignment_dist), "--max-angle", str(assignment_angle)])

    print("[5/5] build_fused_planes")
    sh([py, os.path.join(HERE, "build_fused_planes.py"),
        "--stack", stack, "--fusion", fusion, "--planes", args_planes, "--out-dir", out])

    fused = json.load(open(os.path.join(out, "fused_planes.json")))
    fused.setdefault("source", {})["candidate_source"] = candidate_source
    fused["source"]["analysis_frame"] = "arkit" if analysis_similarity else "scaled_oc"
    detected = to_detected_planes(
        fused, oc_scale=scale, analysis_similarity=analysis_similarity)
    with open(os.path.join(out, "detected_planes.json"), "w") as f:
        json.dump(detected, f)
    tot = sum(p["area_m2"] for p in detected["planes"])
    print(f"\nOK: {len(detected['planes'])} piani fused, area totale {tot:.0f} m²")
    print(f"    -> {out}/fused_planes.json + detected_planes.json")


if __name__ == "__main__":
    main()
