#!/usr/bin/env python3
import argparse
import json
import math
import os


SCALE = float(os.environ.get("ACRO_OC_SCALE", "6.092744385757986"))


PALETTE = [
    "#1f77b4",
    "#ff7f0e",
    "#2ca02c",
    "#d62728",
    "#9467bd",
    "#8c564b",
    "#e377c2",
    "#17becf",
]


def xz(p):
    return (float(p[0]), float(p[2]))


def angle_diff(a, b):
    d = abs((a - b + 90.0) % 180.0 - 90.0)
    return d


def seg_angle(a, b):
    return math.degrees(math.atan2(b[2] - a[2], b[0] - a[0])) % 180.0


def seg_len(a, b):
    ax, az = xz(a)
    bx, bz = xz(b)
    return math.hypot(ax - bx, az - bz)


def signed_plane_distance(p, plane):
    n = plane["normal"]
    q = plane["point"]
    return (p[0] - q[0]) * n[0] + (p[1] - q[1]) * n[1] + (p[2] - q[2]) * n[2]


def snap_to_plane_keep_y(p, plane):
    n = plane["normal"]
    denom = n[0] * n[0] + n[2] * n[2]
    if denom <= 1e-9:
        return p[:]
    d = signed_plane_distance(p, plane)
    return [p[0] - d * n[0] / denom, p[1], p[2] - d * n[2] / denom]


def intersect_vertical_planes_at_y(plane_a, plane_b, y):
    na = plane_a["normal"]
    nb = plane_b["normal"]
    pa = plane_a["point"]
    pb = plane_b["point"]
    ca = na[0] * pa[0] + na[2] * pa[2]
    cb = nb[0] * pb[0] + nb[2] * pb[2]
    det = na[0] * nb[2] - nb[0] * na[2]
    if abs(det) <= 1e-9:
        return None
    x = (ca * nb[2] - cb * na[2]) / det
    z = (na[0] * cb - nb[0] * ca) / det
    return [x, y, z]


def plane_by_id(planes):
    return {p["id"]: p for p in planes}


def joined_vertex(original, prev_segment, next_segment, planes_by_id):
    prev_plane = planes_by_id.get(prev_segment["plane_id"]) if prev_segment else None
    next_plane = planes_by_id.get(next_segment["plane_id"]) if next_segment else None

    if prev_plane and next_plane:
        if prev_plane["id"] == next_plane["id"]:
            return snap_to_plane_keep_y(original, prev_plane)
        intersection = intersect_vertical_planes_at_y(prev_plane, next_plane, original[1])
        if intersection is not None:
            return intersection
        # Parallel or near-parallel planes: keep a midpoint between the two projections.
        a = snap_to_plane_keep_y(original, prev_plane)
        b = snap_to_plane_keep_y(original, next_plane)
        return [(a[0] + b[0]) * 0.5, original[1], (a[2] + b[2]) * 0.5]

    if prev_plane:
        return snap_to_plane_keep_y(original, prev_plane)
    if next_plane:
        return snap_to_plane_keep_y(original, next_plane)
    return original[:]


def join_segments(slice_data, planes, segments):
    contours = slice_data.get("contours", [])
    if not contours or not segments:
        return []

    pts = contours[0].get("regularized", [])
    if len(pts) != len(segments) + 1:
        return []

    by_id = plane_by_id(planes)
    joined = []
    for i, p in enumerate(pts):
        prev_seg = segments[i - 1] if i > 0 else None
        next_seg = segments[i] if i < len(segments) else None
        joined.append(joined_vertex(p, prev_seg, next_seg, by_id))

    for i, seg in enumerate(segments):
        seg["joined_a"] = joined[i]
        seg["joined_b"] = joined[i + 1]
        seg["joined_length"] = seg_len(joined[i], joined[i + 1])
    return joined


def load_planes(path, verticalize):
    data = json.load(open(path))
    coordinate_scale = 1.0 if data.get("scale") == "metric" else SCALE
    out = []
    color_i = 0
    for p in data["planes"]:
        n = p["normale"]
        if abs(n[1]) > 0.30:
            continue
        if verticalize:
            nx, _, nz = n
            length = math.hypot(nx, nz)
            if length <= 1e-9:
                continue
            n = [nx / length, 0.0, nz / length]
        dx = -n[2]
        dz = n[0]
        angle = math.degrees(math.atan2(dz, dx)) % 180.0
        corners = [[v[0] * coordinate_scale, v[1] * coordinate_scale,
                    v[2] * coordinate_scale] for v in p.get("corners", [])]
        support_bounds = p.get("support_bounds")
        if support_bounds:
            support_bounds = {
                key: float(value) * coordinate_scale
                for key, value in support_bounds.items()
            }
        out.append({
            "id": p["id"],
            "name": p["nome"],
            "type": p["tipo"],
            "normal": n,
            "point": [v * coordinate_scale for v in p["punto"]],
            "angle": angle,
            "corners": corners,
            "color": PALETTE[color_i % len(PALETTE)],
            "rms": p.get("rms_m"),
            "score": p.get("score"),
            "area_m2": p.get("area_m2"),
            "support_bounds": support_bounds,
        })
        color_i += 1
    return out


def assign_segments(slice_data, planes, max_dist, max_angle):
    segments = []
    contours = slice_data.get("contours", [])
    if not contours:
        return segments
    pts = contours[0].get("regularized", [])
    for i in range(1, len(pts)):
        a = pts[i - 1]
        b = pts[i]
        length = seg_len(a, b)
        if length <= 1e-6:
            continue
        angle = seg_angle(a, b)
        mid = [(a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5]
        best = None
        for plane in planes:
            dist = abs(signed_plane_distance(mid, plane))
            adiff = angle_diff(angle, plane["angle"])
            if dist > max_dist or adiff > max_angle:
                continue
            score = dist + adiff * 0.08
            if best is None or score < best["score"]:
                best = {
                    "plane": plane,
                    "distance": dist,
                    "angle_diff": adiff,
                    "score": score,
                }

        if best:
            plane = best["plane"]
            snapped_a = snap_to_plane_keep_y(a, plane)
            snapped_b = snap_to_plane_keep_y(b, plane)
            plane_id = plane["id"]
            color = plane["color"]
            plane_name = plane["name"]
        else:
            snapped_a = a
            snapped_b = b
            plane_id = None
            color = "#111111"
            plane_name = "unassigned"

        segments.append({
            "index": i - 1,
            "a": a,
            "b": b,
            "snapped_a": snapped_a,
            "snapped_b": snapped_b,
            "length": length,
            "angle": angle,
            "plane_id": plane_id,
            "plane_name": plane_name,
            "color": color,
            "distance": best["distance"] if best else None,
            "angle_diff": best["angle_diff"] if best else None,
        })
    return segments


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stack_json")
    ap.add_argument("planes_json")
    ap.add_argument("out_json")
    ap.add_argument("--slice-index", type=int, default=27)
    ap.add_argument("--max-dist", type=float, default=2.5)
    ap.add_argument("--max-angle", type=float, default=18.0)
    ap.add_argument("--no-verticalize", action="store_true")
    args = ap.parse_args()

    stack = json.load(open(args.stack_json))
    slice_data = stack["slices"][args.slice_index]
    planes = load_planes(args.planes_json, not args.no_verticalize)
    segments = assign_segments(slice_data, planes, args.max_dist, args.max_angle)
    joined = join_segments(slice_data, planes, segments)
    counts = {}
    for s in segments:
        key = str(s["plane_id"]) if s["plane_id"] is not None else "unassigned"
        counts[key] = counts.get(key, 0) + 1

    out = {
        "slice": slice_data,
        "slice_number": args.slice_index + 1,
        "planes": planes,
        "segments": segments,
        "joined": joined,
        "stats": {
            "segments": len(segments),
            "assigned": sum(1 for s in segments if s["plane_id"] is not None),
            "joined_vertices": len(joined),
            "counts": counts,
            "max_dist": args.max_dist,
            "max_angle": args.max_angle,
        },
    }
    with open(args.out_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(json.dumps(out["stats"]))


if __name__ == "__main__":
    main()
