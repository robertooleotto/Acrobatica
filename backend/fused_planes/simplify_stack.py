#!/usr/bin/env python3
import argparse
import json
import math


def xz(p):
    return (float(p[0]), float(p[2]))


def dist_point_segment(p, a, b):
    px, pz = xz(p)
    ax, az = xz(a)
    bx, bz = xz(b)
    dx = bx - ax
    dz = bz - az
    denom = dx * dx + dz * dz
    if denom <= 1e-12:
        return math.hypot(px - ax, pz - az)
    t = ((px - ax) * dx + (pz - az) * dz) / denom
    t = max(0.0, min(1.0, t))
    qx = ax + t * dx
    qz = az + t * dz
    return math.hypot(px - qx, pz - qz)


def rdp_open(points, epsilon):
    if len(points) <= 2:
        return points[:]

    best_i = -1
    best_d = -1.0
    a = points[0]
    b = points[-1]
    for i in range(1, len(points) - 1):
        d = dist_point_segment(points[i], a, b)
        if d > best_d:
            best_d = d
            best_i = i

    if best_d <= epsilon:
        return [points[0], points[-1]]

    left = rdp_open(points[: best_i + 1], epsilon)
    right = rdp_open(points[best_i:], epsilon)
    return left[:-1] + right


def path_length(points):
    return sum(math.dist(xz(points[i - 1]), xz(points[i])) for i in range(1, len(points)))


def basis(angle_deg):
    a = math.radians(angle_deg)
    return (math.cos(a), math.sin(a)), (-math.sin(a), math.cos(a))


def to_basis(p, u, v):
    x, z = xz(p)
    return [x * u[0] + z * u[1], x * v[0] + z * v[1]]


def from_basis(q, y, u, v):
    return [q[0] * u[0] + q[1] * v[0], y, q[0] * u[1] + q[1] * v[1]]


def weighted_clusters(values, tolerance):
    if not values:
        return {}

    ordered = sorted(values, key=lambda item: item[0])
    groups = []
    current = [ordered[0]]
    for item in ordered[1:]:
        center = sum(v * w for v, w, _ in current) / sum(w for _, w, _ in current)
        if abs(item[0] - center) <= tolerance:
            current.append(item)
        else:
            groups.append(current)
            current = [item]
    groups.append(current)

    snapped = {}
    for group in groups:
        weight = sum(w for _, w, _ in group)
        center = sum(v * w for v, w, _ in group) / weight
        for _, _, idx in group:
            snapped[idx] = center
    return snapped


def merge_collinear_axis(points, u, v, tolerance=1e-4):
    if len(points) <= 2:
        return points[:]

    q = [to_basis(p, u, v) for p in points]
    keep = [points[0]]
    for i in range(1, len(points) - 1):
        a = q[i - 1]
        b = q[i]
        c = q[i + 1]
        same_s = abs(a[0] - b[0]) <= tolerance and abs(b[0] - c[0]) <= tolerance
        same_t = abs(a[1] - b[1]) <= tolerance and abs(b[1] - c[1]) <= tolerance
        if same_s or same_t:
            continue
        keep.append(points[i])
    keep.append(points[-1])
    return keep


def is_axis_aligned(a, b, u, v, tolerance=1e-4):
    qa = to_basis(a, u, v)
    qb = to_basis(b, u, v)
    return abs(qa[0] - qb[0]) <= tolerance or abs(qa[1] - qb[1]) <= tolerance


def prune_short_axis_edges(points, closed, u, v, min_edge, tolerance=1e-4):
    if min_edge <= 0 or len(points) <= 2:
        return points[:]

    pts = points[:]
    if closed and math.dist(xz(pts[0]), xz(pts[-1])) <= tolerance:
        pts = pts[:-1]

    changed = True
    while changed and len(pts) > (3 if closed else 2):
        changed = False

        if not closed:
            while len(pts) > 2 and math.dist(xz(pts[0]), xz(pts[1])) < min_edge:
                pts.pop(0)
                changed = True
            while len(pts) > 2 and math.dist(xz(pts[-2]), xz(pts[-1])) < min_edge:
                pts.pop()
                changed = True

        n = len(pts)
        seg_count = n if closed else n - 1
        for i in range(seg_count):
            j = (i + 1) % n
            if math.dist(xz(pts[i]), xz(pts[j])) >= min_edge:
                continue

            prev_i = (i - 1) % n
            next_j = (j + 1) % n

            if not closed and (i == 0 or j == n - 1):
                continue

            can_bridge_pair = is_axis_aligned(pts[prev_i], pts[next_j], u, v, tolerance)
            if can_bridge_pair and len(pts) > (4 if closed else 3):
                for idx in sorted([i, j], reverse=True):
                    pts.pop(idx)
                changed = True
                break

            can_drop_i = is_axis_aligned(pts[prev_i], pts[j], u, v, tolerance)
            can_drop_j = is_axis_aligned(pts[i], pts[next_j], u, v, tolerance)
            if can_drop_i and can_drop_j:
                len_drop_i = math.dist(xz(pts[prev_i]), xz(pts[j]))
                len_drop_j = math.dist(xz(pts[i]), xz(pts[next_j]))
                pts.pop(i if len_drop_i <= len_drop_j else j)
                changed = True
                break
            if can_drop_i:
                pts.pop(i)
                changed = True
                break
            if can_drop_j:
                pts.pop(j)
                changed = True
                break

    if closed and pts and math.dist(xz(pts[0]), xz(pts[-1])) > tolerance:
        pts.append(pts[0])
    return pts


def dedupe(points, tolerance=1e-4):
    out = []
    for p in points:
        if not out or math.dist(xz(out[-1]), xz(p)) > tolerance:
            out.append(p)
    return out


def repair_axis_edges(points, closed, u, v, tolerance=1e-4):
    if len(points) <= 1:
        return points[:]

    pts = points[:]
    explicit_closed = closed and math.dist(xz(pts[0]), xz(pts[-1])) <= tolerance
    if explicit_closed:
        pts = pts[:-1]

    out = []
    count = len(pts)
    seg_count = count if closed else count - 1
    for i in range(seg_count):
        a = pts[i]
        b = pts[(i + 1) % count]
        if not out:
            out.append(a)
        qa = to_basis(a, u, v)
        qb = to_basis(b, u, v)
        same_s = abs(qa[0] - qb[0]) <= tolerance
        same_t = abs(qa[1] - qb[1]) <= tolerance
        if same_s or same_t:
            out.append(b)
            continue

        # Split accidental diagonal chords into two legal orthogonal segments.
        elbow = from_basis([qb[0], qa[1]], float(a[1]), u, v)
        if math.dist(xz(out[-1]), xz(elbow)) > tolerance:
            out.append(elbow)
        out.append(b)

    if not closed and pts:
        if math.dist(xz(out[-1]), xz(pts[-1])) > tolerance:
            out.append(pts[-1])
    if closed and out and math.dist(xz(out[0]), xz(out[-1])) > tolerance:
        out.append(out[0])
    return dedupe(out, tolerance)


def regularize_to_orthogonal_grid(points, closed, angle_deg, line_tolerance):
    if len(points) <= 2:
        return points[:]

    u, v = basis(angle_deg)
    y = float(points[0][1])
    pts = points[:]
    if closed and math.dist(xz(pts[0]), xz(pts[-1])) > 1e-6:
        pts = pts + [pts[0]]

    q = [to_basis(p, u, v) for p in pts]
    nseg = len(q) - 1
    if nseg <= 0:
        return pts

    orientations = []
    h_values = []
    v_values = []
    for i in range(nseg):
        ds = q[i + 1][0] - q[i][0]
        dt = q[i + 1][1] - q[i][1]
        length = math.hypot(ds, dt)
        if abs(ds) >= abs(dt):
            orientations.append("h")
            h_values.append(((q[i][1] + q[i + 1][1]) * 0.5, max(length, 1e-6), i))
        else:
            orientations.append("v")
            v_values.append(((q[i][0] + q[i + 1][0]) * 0.5, max(length, 1e-6), i))

    h_snap = weighted_clusters(h_values, line_tolerance)
    v_snap = weighted_clusters(v_values, line_tolerance)

    out_q = []
    last_vertex = len(q) - 1
    for i, original in enumerate(q):
        prev_i = (i - 1) % nseg
        next_i = i if i < nseg else 0
        has_prev = closed or i > 0
        has_next = closed or i < last_vertex
        s = original[0]
        t = original[1]

        prev_o = orientations[prev_i] if has_prev else None
        next_o = orientations[next_i] if has_next else None

        if prev_o == "v":
            s = v_snap[prev_i]
        if next_o == "v":
            s = v_snap[next_i]
        if prev_o == "h":
            t = h_snap[prev_i]
        if next_o == "h":
            t = h_snap[next_i]

        out_q.append([s, t])

    out = [from_basis(p, y, u, v) for p in out_q]
    out = dedupe(out)
    out = repair_axis_edges(out, closed, u, v)
    out = merge_collinear_axis(out, u, v)
    out = repair_axis_edges(out, closed, u, v)
    if closed and out and math.dist(xz(out[0]), xz(out[-1])) > 1e-6:
        out.append(out[0])
    return out


def simplify_contour(points, closed, epsilon, min_points_closed, angle_deg, line_tolerance, min_edge):
    pts = points[:]
    if len(pts) <= 2:
        return pts

    if angle_deg is not None and line_tolerance > 0:
        simplified = regularize_to_orthogonal_grid(pts, closed, angle_deg, line_tolerance)
        u, v = basis(angle_deg)
        simplified = prune_short_axis_edges(simplified, closed, u, v, min_edge)
        simplified = repair_axis_edges(simplified, closed, u, v)
        simplified = merge_collinear_axis(dedupe(simplified), u, v)
        simplified = repair_axis_edges(simplified, closed, u, v)
        if closed and simplified and math.dist(xz(simplified[0]), xz(simplified[-1])) > 1e-6:
            simplified.append(simplified[0])
        if closed and len(simplified) < min_points_closed + 1:
            return pts
        return simplified

    if closed:
        # CGAL closed contours sometimes come back with a small endpoint gap.
        # Normalize to an explicit ring before simplification and return a ring.
        if math.dist(xz(pts[0]), xz(pts[-1])) > 1e-6:
            pts = pts + [pts[0]]

        simplified = rdp_open(pts, epsilon)
        if math.dist(xz(simplified[0]), xz(simplified[-1])) > 1e-6:
            simplified.append(simplified[0])

        if len(simplified) < min_points_closed + 1:
            # Too few points means the simplifier collapsed an opening/balcony.
            return pts
        return simplified

    simplified = rdp_open(pts, epsilon)
    if len(simplified) < 2:
        return pts
    return simplified


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--epsilon", type=float, default=0.18)
    ap.add_argument("--line-tolerance", type=float, default=0.0)
    ap.add_argument("--min-edge", type=float, default=0.0)
    ap.add_argument("--angle-deg", type=float, default=None)
    ap.add_argument("--source-key", default="regularized_original")
    ap.add_argument("--min-points-closed", type=int, default=6)
    args = ap.parse_args()

    data = json.load(open(args.input))
    angle_deg = args.angle_deg
    if angle_deg is None:
        angle_deg = data.get("global_angle_deg")

    for s in data.get("slices", []):
        main_pts = 0
        for c in s.get("contours", []):
            source = c.get(args.source_key) or c.get("regularized_original") or c.get("regularized") or []
            if not source:
                continue
            if "regularized_original" not in c:
                c["regularized_original"] = c.get("regularized") or source
            c["regularized"] = simplify_contour(
                source,
                bool(c.get("closed")),
                args.epsilon,
                args.min_points_closed,
                angle_deg,
                args.line_tolerance,
                args.min_edge,
            )
        if s.get("contours"):
            main_pts = len(s["contours"][0].get("regularized", []))
        s["main_reg_pts"] = main_pts

    with open(args.output, "w") as f:
        json.dump(data, f, separators=(",", ":"))


if __name__ == "__main__":
    main()
