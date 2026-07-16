#!/usr/bin/env python3
import json
import math
import os
import sys
from pathlib import Path

SCALE = float(os.environ.get("ACRO_OC_SCALE", "6.092744385757986"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from assign_slice_to_planes import assign_segments, load_planes  # noqa: E402


def xz_dist(a, b):
    return math.hypot(a[0] - b[0], a[2] - b[2])


def distance(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def norm(v):
    length = math.sqrt(dot(v, v))
    if length <= 1e-12:
        return [0.0, 1.0, 0.0]
    return [v[0] / length, v[1] / length, v[2] / length]


def signed_plane_distance(p, normal, point):
    return dot([p[0] - point[0], p[1] - point[1], p[2] - point[2]], normal)


def plane_constant(normal, point):
    return dot(normal, point)


def project_keep_y(p, normal, point):
    denom = normal[0] * normal[0] + normal[2] * normal[2]
    if denom <= 1e-12:
        return p[:]
    d = signed_plane_distance(p, normal, point)
    return [p[0] - d * normal[0] / denom, p[1], p[2] - d * normal[2] / denom]


def intersect_planes_at_y(plane_a, plane_b, y):
    na = plane_a["normal"]
    nb = plane_b["normal"]
    ca = plane_constant(na, plane_a["point"]) - na[1] * y
    cb = plane_constant(nb, plane_b["point"]) - nb[1] * y
    det = na[0] * nb[2] - nb[0] * na[2]
    if abs(det) <= 1e-9:
        return None
    x = (ca * nb[2] - cb * na[2]) / det
    z = (na[0] * cb - nb[0] * ca) / det
    return [x, y, z]


def plane_vertical_direction(normal):
    # Projection of world-up onto the plane. This preserves the real CGAL tilt while
    # still giving us a mostly vertical extrusion direction.
    up = [0.0, 1.0, 0.0]
    d = dot(up, normal)
    return norm([up[0] - d * normal[0], up[1] - d * normal[1], up[2] - d * normal[2]])


def point_on_plane_with_y(base, normal, point, y):
    direction = plane_vertical_direction(normal)
    if abs(direction[1]) <= 1e-9:
        p = base[:]
        p[1] = y
        return project_keep_y(p, normal, point)
    t = (y - base[1]) / direction[1]
    return [
        base[0] + direction[0] * t,
        y,
        base[2] + direction[2] * t,
    ]


def original_planes_by_id(path):
    data = json.load(open(path))
    out = {}
    for plane in data["planes"]:
        normal = norm(plane["normale"])
        out[plane["id"]] = {
            "normal": normal,
            "point": [v * SCALE for v in plane["punto"]],
            "name": plane["nome"],
            "type": plane["tipo"],
        }
    return out


def weighted_main_offset(samples, bin_size=0.25):
    bins = {}
    for _, offset, weight in samples:
        key = round(offset / bin_size) * bin_size
        bins[key] = bins.get(key, 0.0) + weight
    if not bins:
        return 0.0
    best = max(bins.items(), key=lambda item: item[1])[0]
    nearby = [
        (offset, weight)
        for _, offset, weight in samples
        if abs(offset - best) <= bin_size * 1.5
    ]
    weight = sum(w for _, w in nearby)
    if weight <= 1e-9:
        return best
    return sum(o * w for o, w in nearby) / weight


def robust_facade_samples(samples, max_offset_from_main=0.55):
    if not samples:
        return []
    center = weighted_main_offset(samples)
    inliers = [
        (y, offset, weight)
        for y, offset, weight in samples
        if abs(offset - center) <= max_offset_from_main
    ]
    if sum(w for _, _, w in inliers) < 8.0:
        return samples

    # One refinement pass around the inlier mean. This keeps the broad facade band
    # while rejecting balcony peaks and isolated dents.
    total = sum(w for _, _, w in inliers)
    refined_center = sum(offset * weight for _, offset, weight in inliers) / total
    refined = [
        (y, offset, weight)
        for y, offset, weight in samples
        if abs(offset - refined_center) <= max_offset_from_main
    ]
    return refined if refined else inliers


def fit_perimeter_planes(stack, planes_path):
    planes = load_planes(planes_path, True)
    vertical_by_id = {p["id"]: p for p in planes}
    samples = {p["id"]: [] for p in planes}

    for slice_data in stack["slices"]:
        segments = assign_segments(slice_data, planes, max_dist=2.5, max_angle=14.0)
        for seg in segments:
            plane_id = seg.get("plane_id")
            if plane_id is None:
                continue
            plane = vertical_by_id[plane_id]
            midpoint = [
                (seg["a"][0] + seg["b"][0]) * 0.5,
                (seg["a"][1] + seg["b"][1]) * 0.5,
                (seg["a"][2] + seg["b"][2]) * 0.5,
            ]
            normal = plane["normal"]
            point = plane["point"]
            offset = signed_plane_distance(midpoint, normal, point)
            samples[plane_id].append((midpoint[1], offset, max(seg["length"], 1e-6)))

    fitted = {}
    for plane in planes:
        raw_values = samples.get(plane["id"], [])
        values = robust_facade_samples(raw_values)
        total_weight = sum(w for _, _, w in values)
        ys = [y for y, _, _ in values]
        if total_weight < 8.0 or not ys or max(ys) - min(ys) < 1.5:
            fitted[plane["id"]] = {
                **plane,
                "fit_mode": "vertical_fallback",
                "fit_samples": len(values),
                "fit_raw_samples": len(raw_values),
                "fit_weight": total_weight,
            }
            continue

        mean_y = sum(y * w for y, _, w in values) / total_weight
        mean_o = sum(o * w for _, o, w in values) / total_weight
        denom = sum(w * (y - mean_y) ** 2 for y, _, w in values)
        slope = 0.0 if denom <= 1e-9 else sum(w * (y - mean_y) * (o - mean_o) for y, o, w in values) / denom
        # Clamp extreme tilt; perimeter slices should refine a facade gently, not turn
        # a local CGAL patch into a strongly leaning wall.
        slope = max(-0.08, min(0.08, slope))
        intercept = mean_o - slope * mean_y

        nh = plane["normal"]
        point = plane["point"]
        normal = norm([nh[0], -slope, nh[2]])
        fitted_point = [
            point[0] + intercept * nh[0],
            0.0,
            point[2] + intercept * nh[2],
        ]
        fitted[plane["id"]] = {
            **plane,
            "normal": normal,
            "point": fitted_point,
            "fit_mode": "perimeter_regression",
            "fit_samples": len(values),
            "fit_raw_samples": len(raw_values),
            "fit_weight": total_weight,
            "fit_slope": slope,
            "fit_intercept": intercept,
        }
    return fitted


def plane_area(a, b, ymin, ymax):
    return xz_dist(a, b) * (ymax - ymin)


def useful_height_bounds(stack):
    useful = [
        s for s in stack["slices"]
        if s.get("main_length", 0.0) >= 5.0 and s.get("main_reg_pts", 0) >= 3
    ]
    if not useful:
        return stack["ymin"], stack["ymax"]
    return useful[0]["y"], useful[-1]["y"]


def estimate_common_extrusion(planes, max_lean=0.08):
    """Stima un'unica direzione di elevazione per l'intera catena di piani.

    Ogni normale fornisce il vincolo h·d = slope, dove h e' la sua direzione
    orizzontale e d lo spostamento XZ per un metro verticale. Il fit ai minimi
    quadrati evita che le inclinazioni indipendenti delle spallette deformino
    gli spigoli condivisi.
    """
    m00 = m01 = m11 = b0 = b1 = total_weight = 0.0
    for plane in planes:
        normal = norm(plane.get("normal") or plane.get("normale"))
        horizontal = math.hypot(normal[0], normal[2])
        if horizontal <= 1e-9:
            continue
        hx, hz = normal[0] / horizontal, normal[2] / horizontal
        slope = max(-max_lean, min(max_lean, -normal[1] / horizontal))
        weight = max(float(plane.get("fit_weight") or 1.0), 1.0)
        if plane.get("type") in {"spalla", "spalletta"}:
            weight *= 0.35
        m00 += weight * hx * hx
        m01 += weight * hx * hz
        m11 += weight * hz * hz
        b0 += weight * hx * slope
        b1 += weight * hz * slope
        total_weight += weight

    if total_weight <= 0.0:
        return [0.0, 1.0, 0.0]

    # La regolarizzazione rende stabile anche il caso con una sola direzione di
    # facciata: la componente di inclinazione non osservabile resta nulla.
    ridge = max((m00 + m11) * 1e-6, 1e-9)
    m00 += ridge
    m11 += ridge
    determinant = m00 * m11 - m01 * m01
    if abs(determinant) <= 1e-12:
        return [0.0, 1.0, 0.0]
    dx = (b0 * m11 - b1 * m01) / determinant
    dz = (m00 * b1 - m01 * b0) / determinant
    lean = math.hypot(dx, dz)
    if lean > max_lean:
        scale = max_lean / lean
        dx *= scale
        dz *= scale
    return norm([dx, 1.0, dz])


def regularize_plane_for_extrusion(plane, extrusion, reference_y):
    """Mantiene azimut e posizione del piano, ma lo rende parallelo
    all'unica direzione di elevazione condivisa dall'edificio."""
    original_normal = norm(plane.get("normal") or plane.get("normale"))
    horizontal = math.hypot(original_normal[0], original_normal[2])
    if horizontal <= 1e-9:
        return dict(plane)
    hx, hz = original_normal[0] / horizontal, original_normal[2] / horizontal
    normal = norm([hx, -(hx * extrusion[0] + hz * extrusion[2]) / extrusion[1], hz])
    original_point = plane["point"]
    anchor = point_on_plane_with_y(
        original_point, original_normal, original_point, reference_y)
    return {**plane, "normal": normal, "point": anchor}


def project_along_to_plane(point, direction, plane_point):
    """Proietta lungo `direction` sul piano ortogonale alla stessa direzione."""
    amount = dot([point[i] - plane_point[i] for i in range(3)], direction)
    return [point[i] - direction[i] * amount for i in range(3)]


def coalesce_plane_segments(segments, max_unassigned_bridge=2.0):
    """Bridge short protrusions between consecutive pieces of the same plane."""
    out = []
    pending_unassigned = []
    for segment in segments:
        if segment.get("plane_id") is None:
            pending_unassigned.append(segment)
            continue
        if xz_dist(segment["joined_a"], segment["joined_b"]) < 0.25:
            continue

        bridge_length = sum(float(s.get("length", 0.0)) for s in pending_unassigned)
        can_bridge = (
            out
            and out[-1].get("plane_id") == segment.get("plane_id")
            and pending_unassigned
            and bridge_length <= max_unassigned_bridge
        )
        if can_bridge:
            out[-1]["joined_b"] = segment["joined_b"]
            out[-1]["joined_length"] = xz_dist(out[-1]["joined_a"], segment["joined_b"])
            out[-1]["bridged_unassigned_m"] = bridge_length
        else:
            out.append(dict(segment))
        pending_unassigned = []
    return out


def build_planes(fusion, original_by_id, ymin, ymax):
    by_id = {p["id"]: p for p in fusion["planes"]}
    out = []
    source_segments = coalesce_plane_segments(fusion["segments"])
    if not source_segments:
        return out

    raw_sources = {
        segment["plane_id"]: (
            original_by_id.get(segment["plane_id"]) or by_id[segment["plane_id"]])
        for segment in source_segments
        if segment.get("plane_id") is not None
    }
    extrusion = estimate_common_extrusion(raw_sources.values())
    reference_points = [
        point
        for segment in source_segments
        for point in (segment["joined_a"], segment["joined_b"])
    ]
    reference_y = sum(point[1] for point in reference_points) / len(reference_points)
    reference_origin = [
        sum(point[0] for point in reference_points) / len(reference_points),
        reference_y,
        sum(point[2] for point in reference_points) / len(reference_points),
    ]
    sources = {
        plane_id: regularize_plane_for_extrusion(source, extrusion, reference_y)
        for plane_id, source in raw_sources.items()
    }
    lower_offset = (ymin - reference_y) / extrusion[1]
    upper_offset = (ymax - reference_y) / extrusion[1]

    def translated(point, amount):
        return [point[i] + extrusion[i] * amount for i in range(3)]

    def reference_edge_point(original_point, current, neighbor):
        point = None
        if neighbor and neighbor["id"] != current["id"]:
            point = intersect_planes_at_y(current, neighbor, reference_y)
        if point is None:
            projected = project_keep_y(original_point, current["normal"], current["point"])
            point = point_on_plane_with_y(
                projected, current["normal"], current["point"], reference_y)
        # Le intersezioni sono parallele all'estrusione comune. Portarle sullo
        # stesso piano ortogonale produce un anello che, estruso, genera rettangoli.
        return project_along_to_plane(point, extrusion, reference_origin)

    for idx, seg in enumerate(source_segments):
        plane_id = seg.get("plane_id")
        a = seg["joined_a"]
        b = seg["joined_b"]
        source = sources[plane_id]
        normal = source["normal"]
        point = source["point"]
        current = {"id": plane_id, "normal": normal, "point": point}

        prev_seg = source_segments[idx - 1] if idx > 0 else None
        next_seg = source_segments[idx + 1] if idx + 1 < len(source_segments) else None
        prev_plane = None
        next_plane = None
        if prev_seg and prev_seg.get("plane_id") is not None:
            p = sources[prev_seg["plane_id"]]
            prev_plane = {"id": prev_seg["plane_id"], "normal": p["normal"], "point": p["point"]}
        if next_seg and next_seg.get("plane_id") is not None:
            p = sources[next_seg["plane_id"]]
            next_plane = {"id": next_seg["plane_id"], "normal": p["normal"], "point": p["point"]}

        reference_a = reference_edge_point(a, current, prev_plane)
        reference_b = reference_edge_point(b, current, next_plane)
        bottom_a = translated(reference_a, lower_offset)
        bottom_b = translated(reference_b, lower_offset)
        top_b = translated(reference_b, upper_offset)
        top_a = translated(reference_a, upper_offset)
        corners = [
            bottom_a,
            bottom_b,
            top_b,
            top_a,
        ]
        width = distance(bottom_a, bottom_b)
        height = distance(bottom_a, top_a)
        area = width * height
        center = [sum(corner[i] for corner in corners) / 4.0 for i in range(3)]
        out.append({
            "id": seg["index"],
            "nome": f"{source['name']} · seg {seg['index']}",
            "tipo": source.get("type", "facciata"),
            "punto": center,
            "normale": normal,
            "corners": corners,
            "area_m2": area,
            "tri_area_m2": area,
            "coverage": 1.0,
            "fill_ratio": 1.0,
            "rms_m": seg.get("distance"),
            "score": seg.get("angle_diff"),
            "fit_mode": source.get("fit_mode"),
            "fit_slope": source.get("fit_slope"),
            "fit_samples": source.get("fit_samples"),
            "fit_raw_samples": source.get("fit_raw_samples"),
            "extrusion_direction": extrusion,
            "regularization": "shared_orthogonal_extrusion",
            "w": width,
            "h": height,
            "n_triangoli": 2,
        })
    return out


def write_viewer(out_dir, data, bundle_path):
    out_dir.mkdir(parents=True, exist_ok=True)
    import shutil
    bundle_src = Path(bundle_path)
    shutil.copyfile(bundle_src, out_dir / "viewer-bundle.js")
    html = f"""<!doctype html>
<html lang="it">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Mesh originale + piani fused</title>
  <style>
    html, body {{ margin: 0; width: 100%; height: 100%; overflow: hidden; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f5f3ef; }}
    #view {{ position: fixed; inset: 0; }}
    #panel {{ position: fixed; left: 16px; top: 16px; width: 330px; max-height: calc(100vh - 32px); overflow: auto; background: rgba(255,255,255,.88); border: 1px solid rgba(20,20,20,.12); border-radius: 8px; box-shadow: 0 10px 28px rgba(0,0,0,.12); }}
    .head {{ padding: 12px 14px; border-bottom: 1px solid rgba(20,20,20,.10); }}
    h1 {{ margin: 0; font-size: 15px; font-weight: 650; color: #171717; }}
    .meta {{ margin-top: 4px; font-size: 12px; color: #555; }}
    .row {{ display: grid; grid-template-columns: 22px 1fr auto; gap: 8px; align-items: center; padding: 9px 14px; border-bottom: 1px solid rgba(20,20,20,.06); font-size: 13px; }}
    .swatch {{ width: 14px; height: 14px; border-radius: 3px; border: 1px solid rgba(0,0,0,.25); }}
    label {{ min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #222; }}
    .area {{ font-variant-numeric: tabular-nums; color: #555; }}
    .tools {{ display: flex; gap: 8px; padding: 10px 14px; flex-wrap: wrap; }}
    button {{ border: 1px solid rgba(0,0,0,.18); border-radius: 6px; background: white; padding: 7px 10px; cursor: pointer; font-size: 12px; }}
  </style>
</head>
<body>
  <div id="view"></div>
  <aside id="panel">
    <div class="head">
      <h1>Mesh originale + piani fused</h1>
      <div class="meta" id="meta"></div>
    </div>
    <div class="tools">
      <button id="toggleMesh">Mesh</button>
      <button id="allPlanes">Tutti i piani</button>
      <button id="topPlanes">Solo principali</button>
    </div>
    <div id="planes"></div>
  </aside>
  <script type="application/json" id="data">{json.dumps(data, separators=(",", ":"))}</script>
  <script src="./viewer-bundle.js?v=fusedPlanesGrown1"></script>
</body>
</html>
"""
    (out_dir / "viewer.html").write_text(html)


def run(stack_path, fusion_path, planes_path, out_dir, viewer_bundle=None):
    stack_path = Path(stack_path)
    fusion_path = Path(fusion_path)
    planes_path = Path(planes_path)
    out_dir = Path(out_dir)

    stack = json.load(open(stack_path))
    fusion = json.load(open(fusion_path))
    original_by_id = fit_perimeter_planes(stack, planes_path)
    ymin, ymax = useful_height_bounds(stack)
    planes = build_planes(fusion, original_by_id, ymin, ymax)
    data = {
        "planes": planes,
        "source": {
            "slice_number": fusion["slice_number"],
            "threshold_m": stack.get("threshold_m"),
            "angle_deg": stack.get("global_angle_deg"),
            "assigned_segments": fusion["stats"]["assigned"],
            "segments": fusion["stats"]["segments"],
            "plane_mode": "perimeter_fit_shared_lean",
            "edge_mode": "shared_orthogonal_extrusion",
            "extrusion_direction": (
                planes[0].get("extrusion_direction") if planes else [0.0, 1.0, 0.0]),
            "ymin": ymin,
            "ymax": ymax,
        },
    }
    if viewer_bundle:
        data["mesh"] = stack["mesh"]
        write_viewer(out_dir, data, viewer_bundle)
    with open(out_dir / "fused_planes.json", "w") as f:
        json.dump(data, f, separators=(",", ":"))
    print(json.dumps({
        "planes": len(planes),
        "mesh_vertices": len(stack["mesh"]["vertices"]) // 3,
        "mesh_faces": len(stack["mesh"]["faces"]) // 3,
        "out": str(out_dir),
    }))
    return data


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--stack", required=True)
    ap.add_argument("--fusion", required=True)
    ap.add_argument("--planes", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--viewer-bundle")
    args = ap.parse_args()
    run(args.stack, args.fusion, args.planes, args.out_dir, args.viewer_bundle)


if __name__ == "__main__":
    main()
