#!/usr/bin/env python3
"""Build vertical plane candidates from persistent horizontal perimeter lines.

This stage deliberately ignores planar regions in the triangle mesh. A line is
kept only when it can be tracked at nearly the same offset through many height
slices; short-lived roof, balcony and scan-detail contours are discarded.
"""
import argparse
import json
import math


def xz(point):
    return float(point[0]), float(point[2])


def segment_length(a, b):
    ax, az = xz(a)
    bx, bz = xz(b)
    return math.hypot(bx - ax, bz - az)


def axes(angle_deg):
    angle = math.radians(angle_deg)
    primary = (math.cos(angle), math.sin(angle))
    secondary = (-primary[1], primary[0])
    return primary, secondary


def interval_gap(a0, a1, b0, b1):
    return max(0.0, max(a0, b0) - min(a1, b1))


def slice_observations(slice_data, angle_deg, offset_tolerance=0.20,
                       min_segment=0.50, max_axis_angle=12.0):
    """Group collinear pieces from one ring into infinite-line observations."""
    contours = slice_data.get("contours") or []
    if not contours:
        return []
    points = contours[0].get("regularized") or []
    basis = axes(angle_deg)
    raw = {0: [], 1: []}
    for a, b in zip(points, points[1:]):
        length = segment_length(a, b)
        if length < min_segment:
            continue
        dx = float(b[0]) - float(a[0])
        dz = float(b[2]) - float(a[2])
        unit = (dx / length, dz / length)
        alignment = [
            abs(unit[0] * direction[0] + unit[1] * direction[1])
            for direction in basis
        ]
        axis = 0 if alignment[0] >= alignment[1] else 1
        angle_error = math.degrees(math.acos(max(-1.0, min(1.0, alignment[axis]))))
        if angle_error > max_axis_angle:
            continue
        direction = basis[axis]
        normal = (-direction[1], direction[0])
        midpoint = ((float(a[0]) + float(b[0])) * 0.5,
                    (float(a[2]) + float(b[2])) * 0.5)
        offset = midpoint[0] * normal[0] + midpoint[1] * normal[1]
        ta = float(a[0]) * direction[0] + float(a[2]) * direction[1]
        tb = float(b[0]) * direction[0] + float(b[2]) * direction[1]
        raw[axis].append({
            "offset": offset,
            "length": length,
            "t_min": min(ta, tb),
            "t_max": max(ta, tb),
        })

    observations = []
    for axis, items in raw.items():
        groups = []
        for item in sorted(items, key=lambda value: value["offset"]):
            if not groups:
                groups.append([item])
                continue
            group = groups[-1]
            weight = sum(value["length"] for value in group)
            center = sum(value["offset"] * value["length"] for value in group) / weight
            if abs(item["offset"] - center) <= offset_tolerance:
                group.append(item)
            else:
                groups.append([item])
        for group in groups:
            weight = sum(value["length"] for value in group)
            observations.append({
                "axis": axis,
                "slice": int(slice_data.get("index", 0)),
                "y": float(slice_data["y"]),
                "offset": sum(value["offset"] * value["length"] for value in group) / weight,
                "length": weight,
                "t_min": min(value["t_min"] for value in group),
                "t_max": max(value["t_max"] for value in group),
            })
    return observations


def predicted_offset(track, y):
    observations = track["observations"]
    latest = observations[-1]
    if len(observations) < 2:
        return latest["offset"]
    previous = observations[-2]
    dy = latest["y"] - previous["y"]
    slope = 0.0 if abs(dy) < 1e-9 else (
        latest["offset"] - previous["offset"]) / dy
    slope = max(-0.10, min(0.10, slope))
    return latest["offset"] + slope * (y - latest["y"])


def track_observations(stack, angle_deg, track_tolerance=0.45,
                       max_gap_slices=2, tangent_gap=3.0):
    """Associate perimeter lines between adjacent slices without mesh semantics."""
    tracks = []
    next_id = 0
    for slice_data in stack.get("slices", []):
        observations = slice_observations(slice_data, angle_deg)
        used_tracks = set()
        for observation in sorted(observations, key=lambda item: -item["length"]):
            candidates = []
            for track in tracks:
                if track["id"] in used_tracks or track["axis"] != observation["axis"]:
                    continue
                latest = track["observations"][-1]
                gap = observation["slice"] - latest["slice"]
                if gap <= 0 or gap > max_gap_slices + 1:
                    continue
                offset_error = abs(observation["offset"] - predicted_offset(track, observation["y"]))
                if offset_error > track_tolerance:
                    continue
                t_gap = interval_gap(
                    observation["t_min"], observation["t_max"],
                    latest["t_min"], latest["t_max"])
                if t_gap > tangent_gap:
                    continue
                candidates.append((offset_error + t_gap * 0.05 + gap * 0.01, track))
            if candidates:
                track = min(candidates, key=lambda item: item[0])[1]
                track["observations"].append(observation)
                used_tracks.add(track["id"])
            else:
                tracks.append({
                    "id": next_id,
                    "axis": observation["axis"],
                    "observations": [observation],
                })
                used_tracks.add(next_id)
                next_id += 1
    return tracks


def weighted_line_fit(observations):
    total = sum(item["length"] for item in observations)
    mean_y = sum(item["y"] * item["length"] for item in observations) / total
    mean_offset = sum(item["offset"] * item["length"] for item in observations) / total
    denominator = sum(item["length"] * (item["y"] - mean_y) ** 2
                      for item in observations)
    slope = 0.0 if denominator <= 1e-9 else sum(
        item["length"] * (item["y"] - mean_y) * (item["offset"] - mean_offset)
        for item in observations) / denominator
    slope = max(-0.08, min(0.08, slope))
    intercept = mean_offset - slope * mean_y
    return intercept, slope


def persistent_tracks(tracks, total_slices, min_ratio=0.25, min_count=4,
                      min_y_span=1.5, min_support_length=30.0):
    required = max(min_count, math.ceil(total_slices * min_ratio))
    accepted = []
    for track in tracks:
        observations = track["observations"]
        slices = {item["slice"] for item in observations}
        ys = [item["y"] for item in observations]
        support = sum(item["length"] for item in observations)
        if (len(slices) >= required and max(ys) - min(ys) >= min_y_span
                and support >= min_support_length):
            accepted.append(track)
    return accepted


def point_on_tracked_line(direction, normal, tangent, intercept, slope, y):
    offset = intercept + slope * y
    return [
        direction[0] * tangent + normal[0] * offset,
        y,
        direction[1] * tangent + normal[1] * offset,
    ]


def build_candidates(stack, angle_deg, **tracking_options):
    tracks = track_observations(stack, angle_deg, **tracking_options)
    accepted = persistent_tracks(tracks, len(stack.get("slices", [])))
    basis = axes(angle_deg)
    planes = []
    for plane_id, track in enumerate(sorted(
            accepted,
            key=lambda item: (item["axis"], -sum(
                value["length"] for value in item["observations"]))
    )):
        observations = track["observations"]
        intercept, slope = weighted_line_fit(observations)
        direction = basis[track["axis"]]
        horizontal_normal = (-direction[1], direction[0])
        normal_length = math.sqrt(1.0 + slope * slope)
        normal = [horizontal_normal[0] / normal_length,
                  -slope / normal_length,
                  horizontal_normal[1] / normal_length]
        y_min = min(item["y"] for item in observations)
        y_max = max(item["y"] for item in observations)
        t_min = min(item["t_min"] for item in observations)
        t_max = max(item["t_max"] for item in observations)
        corners = [
            point_on_tracked_line(direction, horizontal_normal, t_min, intercept, slope, y_min),
            point_on_tracked_line(direction, horizontal_normal, t_max, intercept, slope, y_min),
            point_on_tracked_line(direction, horizontal_normal, t_max, intercept, slope, y_max),
            point_on_tracked_line(direction, horizontal_normal, t_min, intercept, slope, y_max),
        ]
        width = t_max - t_min
        height = (y_max - y_min) * normal_length
        point = point_on_tracked_line(
            direction, horizontal_normal, (t_min + t_max) * 0.5,
            intercept, slope, (y_min + y_max) * 0.5)
        planes.append({
            "id": plane_id,
            "nome": f"Perimetro {plane_id + 1}",
            "tipo": "facciata",
            "punto": point,
            "normale": normal,
            "corners": corners,
            "area_m2": width * height,
            "w": width,
            "h": height,
            "slice_count": len({item["slice"] for item in observations}),
            "y_span": y_max - y_min,
            "support_length": sum(item["length"] for item in observations),
            "fit_slope": slope,
            "source_track": track["id"],
        })
    return {
        "schema": "perimeter_planes",
        "scale": "metric",
        "angle_deg": angle_deg,
        "tracks_total": len(tracks),
        "tracks_persistent": len(accepted),
        "planes": planes,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stack")
    parser.add_argument("out")
    parser.add_argument("--angle", type=float)
    parser.add_argument("--track-tolerance", type=float, default=0.45)
    parser.add_argument("--max-gap-slices", type=int, default=2)
    parser.add_argument("--tangent-gap", type=float, default=3.0)
    args = parser.parse_args()

    with open(args.stack) as source:
        stack = json.load(source)
    angle = args.angle if args.angle is not None else stack.get("global_angle_deg")
    if angle is None:
        raise SystemExit("angolo globale assente nello stack")
    document = build_candidates(
        stack,
        float(angle),
        track_tolerance=args.track_tolerance,
        max_gap_slices=args.max_gap_slices,
        tangent_gap=args.tangent_gap,
    )
    with open(args.out, "w") as output:
        json.dump(document, output, separators=(",", ":"))
    print(json.dumps({
        "tracks": document["tracks_total"],
        "persistent": document["tracks_persistent"],
        "planes": len(document["planes"]),
        "angle_deg": document["angle_deg"],
    }))


if __name__ == "__main__":
    main()
