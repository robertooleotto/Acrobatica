#!/usr/bin/env python3
"""Reconstruct an open piecewise-planar facade from all horizontal slices.

Unlike the legacy fusion stage, this module never derives the output topology
from one representative ring.  It tracks arbitrary line directions through
height, fits metric planes to their accumulated 3D support and uses observed
contour adjacency to create shared edges.  The result is intentionally open:
unobserved backs, roofs and closure faces are not invented.
"""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

import numpy as np

from build_fused_planes import (
    classify_final_plane_types,
    estimate_common_extrusion,
    write_viewer,
)
from assign_slice_to_planes import load_planes


EPS = 1e-9


def _xz(point):
    return np.asarray([float(point[0]), float(point[2])], dtype=float)


def _unit(vector):
    vector = np.asarray(vector, dtype=float)
    length = float(np.linalg.norm(vector))
    return vector / length if length > EPS else vector


def _angle_distance(a, b):
    delta = abs(float(a) - float(b)) % math.pi
    return min(delta, math.pi - delta)


def _point_segment_distance(point, a, b):
    point, a, b = _xz(point), _xz(a), _xz(b)
    edge = b - a
    denominator = float(edge @ edge)
    if denominator <= EPS:
        return float(np.linalg.norm(point - a))
    amount = max(0.0, min(1.0, float((point - a) @ edge) / denominator))
    return float(np.linalg.norm(point - (a + edge * amount)))


def estimate_contour_noise(stack, sample_limit=6000):
    """Estimate contour simplification residual in metres from the scan itself."""
    residuals = []
    for slice_data in stack.get("slices", []):
        for contour in slice_data.get("contours", []):
            raw = contour.get("raw") or []
            simplified = contour.get("regularized") or []
            if len(raw) < 2 or len(simplified) < 2:
                continue
            stride = max(1, len(raw) // 80)
            for point in raw[::stride]:
                residuals.append(min(
                    _point_segment_distance(point, a, b)
                    for a, b in zip(simplified, simplified[1:])
                ))
                if len(residuals) >= sample_limit:
                    break
            if len(residuals) >= sample_limit:
                break
        if len(residuals) >= sample_limit:
            break
    if not residuals:
        return max(float(stack.get("step_m", 0.3)) * 0.10, 0.01)
    values = np.asarray(residuals, dtype=float)
    # The upper quartile captures scan/simplification uncertainty while ignoring
    # isolated contour failures that would make every plane merge with its neighbour.
    return max(float(np.quantile(values, 0.75)), 0.005)


def derive_thresholds(stack):
    step = max(float(stack.get("step_m", 0.3)), 0.01)
    noise = estimate_contour_noise(stack)
    lengths = []
    for slice_data in stack.get("slices", []):
        for contour in slice_data.get("contours", []):
            points = contour.get("regularized") or []
            lengths.extend(
                float(np.linalg.norm(_xz(b) - _xz(a)))
                for a, b in zip(points, points[1:])
                if np.linalg.norm(_xz(b) - _xz(a)) > EPS
            )
    typical_length = float(np.median(lengths)) if lengths else step * 3.0
    line_distance = max(noise * 3.0, step * 0.35)
    angle = math.atan2(max(noise * 2.0, step * 0.15), max(typical_length, step))
    return {
        "step": step,
        "noise": noise,
        "typical_length": typical_length,
        "min_segment": max(noise * 2.0, step * 0.35),
        "line_distance": line_distance,
        "angle_rad": max(math.radians(2.0), min(math.radians(15.0), angle * 2.0)),
        "max_gap_slices": 3,
        "tangent_gap": max(typical_length * 2.0, line_distance * 6.0),
    }


def extract_segments(stack, thresholds):
    """Return ordered observations; directions are canonical but unrestricted."""
    by_slice = []
    for slice_position, slice_data in enumerate(stack.get("slices", [])):
        observations = []
        y = float(slice_data["y"])
        for contour_index, contour in enumerate(slice_data.get("contours", [])):
            points = contour.get("regularized") or []
            for order, (a, b) in enumerate(zip(points, points[1:])):
                pa, pb = _xz(a), _xz(b)
                vector = pb - pa
                length = float(np.linalg.norm(vector))
                if length < thresholds["min_segment"]:
                    continue
                direction = vector / length
                if direction[0] < -EPS or (abs(direction[0]) <= EPS and direction[1] < 0.0):
                    direction = -direction
                normal = np.asarray([-direction[1], direction[0]])
                midpoint = (pa + pb) * 0.5
                tangent = sorted((float(pa @ direction), float(pb @ direction)))
                observations.append({
                    "slice": slice_position,
                    "source_slice": int(slice_data.get("index", slice_position)),
                    "contour": contour_index,
                    "order": order,
                    "y": y,
                    "a": [float(pa[0]), y, float(pa[1])],
                    "b": [float(pb[0]), y, float(pb[1])],
                    "mid": midpoint,
                    "direction": direction,
                    "normal": normal,
                    "angle": math.atan2(float(direction[1]), float(direction[0])) % math.pi,
                    "offset": float(midpoint @ normal),
                    "t_min": tangent[0],
                    "t_max": tangent[1],
                    "length": length,
                    "track": None,
                })
        by_slice.append(observations)
    return by_slice


def _interval_gap(a0, a1, b0, b1):
    return max(0.0, max(a0, b0) - min(a1, b1))


def _track_prediction(track, y):
    observations = track["observations"]
    latest = observations[-1]
    if len(observations) < 2:
        return latest["offset"]
    previous = observations[-2]
    dy = latest["y"] - previous["y"]
    if abs(dy) <= EPS:
        return latest["offset"]
    return latest["offset"] + (latest["offset"] - previous["offset"]) / dy * (y - latest["y"])


def track_segments(by_slice, thresholds):
    tracks = []
    for observations in by_slice:
        used = set()
        for observation in sorted(observations, key=lambda item: -item["length"]):
            candidates = []
            for track in tracks:
                if track["id"] in used:
                    continue
                latest = track["observations"][-1]
                slice_gap = observation["slice"] - latest["slice"]
                if slice_gap <= 0 or slice_gap > thresholds["max_gap_slices"] + 1:
                    continue
                angle_error = _angle_distance(observation["angle"], latest["angle"])
                if angle_error > thresholds["angle_rad"]:
                    continue
                direction = _unit(observation["direction"] + latest["direction"])
                normal = np.asarray([-direction[1], direction[0]])
                observed_offset = float(observation["mid"] @ normal)
                latest_offset = float(latest["mid"] @ normal)
                predicted = _track_prediction(track, observation["y"])
                predicted += latest_offset - latest["offset"]
                offset_error = abs(observed_offset - predicted)
                if offset_error > thresholds["line_distance"] * (1.0 + 0.35 * (slice_gap - 1)):
                    continue
                obs_t = sorted((float(_xz(observation["a"]) @ direction),
                                float(_xz(observation["b"]) @ direction)))
                old_t = sorted((float(_xz(latest["a"]) @ direction),
                                float(_xz(latest["b"]) @ direction)))
                tangent_gap = _interval_gap(*obs_t, *old_t)
                if tangent_gap > thresholds["tangent_gap"]:
                    continue
                score = (offset_error / thresholds["line_distance"]
                         + angle_error / thresholds["angle_rad"]
                         + tangent_gap / thresholds["tangent_gap"]
                         + slice_gap * 0.02)
                candidates.append((score, track))
            if candidates:
                track = min(candidates, key=lambda item: item[0])[1]
            else:
                track = {"id": len(tracks), "observations": []}
                tracks.append(track)
            track["observations"].append(observation)
            observation["track"] = track["id"]
            used.add(track["id"])
    return tracks


def _fit_track(observations):
    points, weights = [], []
    for observation in observations:
        points.extend((observation["a"], observation["b"]))
        weights.extend((observation["length"] * 0.5, observation["length"] * 0.5))
    points = np.asarray(points, dtype=float)
    weights = np.asarray(weights, dtype=float)
    center = np.average(points, axis=0, weights=weights)
    centered = points - center
    covariance = (centered * weights[:, None]).T @ centered / max(float(weights.sum()), EPS)
    values, vectors = np.linalg.eigh(covariance)
    normal = _unit(vectors[:, int(np.argmin(values))])
    if math.hypot(float(normal[0]), float(normal[2])) <= 0.50:
        return None
    if normal[2] < -EPS or (abs(normal[2]) <= EPS and normal[0] < 0.0):
        normal = -normal
    residuals = np.abs(centered @ normal)
    return {
        "observations": observations,
        "center": center,
        "normal": normal,
        "rms": float(math.sqrt(np.average(residuals ** 2, weights=weights))),
        "slice_ids": {item["slice"] for item in observations},
        "support_area": sum(item["length"] for item in observations),
    }


def persistent_fits(tracks, thresholds):
    fits = []
    min_support = thresholds["min_segment"] * thresholds["step"] * 3.0
    for track in tracks:
        observations = track["observations"]
        slices = {item["slice"] for item in observations}
        ys = [item["y"] for item in observations]
        support_area = sum(item["length"] * thresholds["step"] for item in observations)
        if len(slices) < 3 or max(ys, default=0.0) - min(ys, default=0.0) < thresholds["step"] * 2.0:
            continue
        if support_area < min_support:
            continue
        fit = _fit_track(observations)
        if fit is not None and fit["rms"] <= thresholds["line_distance"] * 1.5:
            fit["id"] = len(fits)
            fit["source_tracks"] = {track["id"]}
            fits.append(fit)
    return fits


def merge_coplanar_fits(fits, thresholds):
    """Merge split tracks only when support overlaps in height and along the plane."""
    parent = list(range(len(fits)))

    def find(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def bounds(fit, direction):
        points = [_xz(point) for obs in fit["observations"] for point in (obs["a"], obs["b"])]
        ts = [float(point @ direction) for point in points]
        ys = [obs["y"] for obs in fit["observations"]]
        return min(ts), max(ts), min(ys), max(ys)

    for i, first in enumerate(fits):
        for j in range(i + 1, len(fits)):
            second = fits[j]
            similarity = abs(float(first["normal"] @ second["normal"]))
            if similarity < math.cos(thresholds["angle_rad"]):
                continue
            separation = abs(float((second["center"] - first["center"]) @ first["normal"]))
            if separation > thresholds["line_distance"]:
                continue
            horizontal = _unit([first["normal"][2], -first["normal"][0]])
            a0, a1, ay0, ay1 = bounds(first, horizontal)
            b0, b1, by0, by1 = bounds(second, horizontal)
            if _interval_gap(ay0, ay1, by0, by1) > thresholds["step"] * thresholds["max_gap_slices"]:
                continue
            if _interval_gap(a0, a1, b0, b1) > thresholds["tangent_gap"]:
                continue
            parent[find(j)] = find(i)

    groups = defaultdict(list)
    for index, fit in enumerate(fits):
        groups[find(index)].append(fit)
    merged = []
    for members in groups.values():
        observations = [obs for member in members for obs in member["observations"]]
        fit = _fit_track(observations)
        if fit is None:
            continue
        fit["id"] = len(merged)
        fit["source_tracks"] = set().union(*(member["source_tracks"] for member in members))
        merged.append(fit)
    return merged


def anchor_fits_to_mesh_planes(fits, candidates_path, thresholds,
                               return_unassigned=False):
    """Fuse slice tracks with CGAL mesh regions and return one fit per region.

    Region growing supplies the existence, position and orientation of a plane;
    slice tracks only add support and extents.  This is the guard that prevents
    repeated mouldings and balcony outlines from becoming facade planes.
    """
    candidates = load_planes(candidates_path, False)
    max_candidate_area = max(
        (float(candidate.get("area_m2") or 0.0) for candidate in candidates),
        default=0.0,
    )
    def assign(candidate_pool):
        groups = defaultdict(list)
        assigned = set()
        for fit in fits:
            best = None
            for candidate in candidate_pool:
                candidate_normal = np.asarray(candidate["normal"], dtype=float)
                if math.hypot(float(candidate_normal[0]), float(candidate_normal[2])) <= 0.50:
                    continue
                similarity = abs(float(fit["normal"] @ candidate_normal))
                if similarity < math.cos(thresholds["angle_rad"]):
                    continue
                candidate_point = np.asarray(candidate["point"], dtype=float)
                distance = abs(float((fit["center"] - candidate_point) @ candidate_normal))
                tolerance = max(
                    thresholds["line_distance"] * 2.5,
                    float(candidate.get("rms") or 0.0) * 3.0,
                )
                if distance > tolerance:
                    continue
                area_ratio = (
                    float(candidate.get("area_m2") or 0.0) / max_candidate_area
                    if max_candidate_area > EPS else 0.0
                )
                support_reward = 0.75 * math.log1p(9.0 * area_ratio)
                score = distance / tolerance + (1.0 - similarity) - support_reward
                if best is None or score < best[0]:
                    best = (score, candidate)
            if best is not None:
                groups[best[1]["id"]].append((fit, best[1]))
                assigned.add(id(fit))
        return groups, [fit for fit in fits if id(fit) not in assigned]

    groups, unassigned = assign(candidates)

    # Separate structural surfaces from repeated details using evidence measured
    # per acquisition. No plane count, expected direction or relative facade width
    # is encoded. Narrow but vertically persistent returns remain in the high-support
    # population because height and slice count are independent of width.
    if len(groups) >= 4:
        group_items = list(groups.items())
        features = []
        for _, members in group_items:
            candidate = members[0][1]
            observations = [
                observation
                for fit, _ in members
                for observation in fit["observations"]
            ]
            support_bounds = candidate.get("support_bounds") or {}
            support_height = max(
                0.0,
                float(support_bounds.get("y_max", 0.0))
                - float(support_bounds.get("y_min", 0.0)),
            )
            slices = {observation["slice"] for observation in observations}
            features.append([
                math.log1p(float(candidate.get("area_m2") or 0.0)),
                math.log1p(support_height),
                math.log1p(len(slices)),
            ])
        values = np.asarray(features, dtype=float)
        median = np.median(values, axis=0)
        spread = np.quantile(values, 0.75, axis=0) - np.quantile(values, 0.25, axis=0)
        values = (values - median) / np.maximum(spread, 1e-6)
        score = values.sum(axis=1)
        centers = np.asarray([values[np.argmin(score)], values[np.argmax(score)]])
        labels = np.zeros(len(values), dtype=int)
        for _ in range(50):
            labels = np.argmin(
                np.sum((values[:, None, :] - centers[None, :, :]) ** 2, axis=2),
                axis=1,
            )
            if any(not np.any(labels == cluster) for cluster in range(2)):
                break
            updated = np.asarray([
                values[labels == cluster].mean(axis=0) for cluster in range(2)
            ])
            if np.allclose(updated, centers):
                break
            centers = updated
        structural_cluster = int(np.argmax(centers.sum(axis=1)))
        structural_ids = {
            group_items[index][0]
            for index in range(len(group_items))
            if labels[index] == structural_cluster
        }
        structural_candidates = [
            candidate for candidate in candidates
            if candidate["id"] in structural_ids
        ]
        if structural_candidates:
            groups, unassigned = assign(structural_candidates)
        else:
            unassigned = []

    anchored = []
    for members in groups.values():
        candidate = members[0][1]
        fitted = _anchor_component(
            members, candidate, thresholds, 0, 1, len(anchored))
        if fitted is not None:
            anchored.append(fitted)
    if return_unassigned:
        return anchored, unassigned
    return anchored


def discover_gap_fits(by_slice, base_fits, unassigned_fits, thresholds,
                      return_bridged_adjacencies=False):
    """Find planes repeatedly occupying a contour gap between two base planes.

    This recovers stepped facade fronts even when ornamentation fragments their
    CGAL region. The identity of the neighbouring planes, not an expected plane
    count or facade position, provides the structural evidence.
    """
    base_by_track = {
        track_id: fit["id"]
        for fit in base_fits
        for track_id in fit["source_tracks"]
    }
    unassigned_by_track = {
        track_id: index
        for index, fit in enumerate(unassigned_fits)
        for track_id in fit["source_tracks"]
    }
    gaps = defaultdict(lambda: {"fits": set(), "slices": set(), "points": []})

    # A missing connector is bounded by the closest parallel supports on each
    # side. Mutual-nearest pairing prevents a temporarily missing observation
    # from opening one gap across several already modelled facade bays.
    nearest_parallel = {}
    for first_id, first in enumerate(base_fits):
        first_normal = _unit([first["normal"][0], first["normal"][2]])
        for second_id, second in enumerate(base_fits):
            if first_id == second_id:
                continue
            second_normal = _unit([second["normal"][0], second["normal"][2]])
            if abs(float(first_normal @ second_normal)) < math.cos(
                    thresholds["angle_rad"]):
                continue
            separation = abs(float(
                (_xz(second["center"]) - _xz(first["center"])) @ first_normal
            ))
            current = nearest_parallel.get(first_id)
            if current is None or separation < current[0]:
                nearest_parallel[first_id] = (separation, second_id)

    for observations in by_slice:
        contours = defaultdict(list)
        for observation in observations:
            contours[observation["contour"]].append(observation)
        for contour in contours.values():
            contour.sort(key=lambda item: item["order"])
            anchors = [
                (index, base_by_track[observation["track"]])
                for index, observation in enumerate(contour)
                if observation["track"] in base_by_track
            ]
            for (start, first_id), (end, second_id) in zip(anchors, anchors[1:]):
                if first_id == second_id or end <= start + 1:
                    continue
                between = {
                    unassigned_by_track[observation["track"]]
                    for observation in contour[start + 1:end]
                    if observation["track"] in unassigned_by_track
                }
                if not between:
                    continue
                key = tuple(sorted((first_id, second_id)))
                gaps[key]["fits"].update(between)
                gaps[key]["slices"].add(contour[start]["slice"])
                gap_point = (
                    np.asarray(contour[start]["b"], dtype=float)
                    + np.asarray(contour[end]["a"], dtype=float)
                ) * 0.5
                gaps[key]["points"].append((
                    gap_point.tolist(), contour[start]["slice"]
                ))

    supplemental = []
    bridged_adjacencies = defaultdict(list)
    used_fits = set()
    for neighbor_ids, evidence in sorted(gaps.items()):
        first_id, second_id = neighbor_ids
        mutually_nearest = (
            nearest_parallel.get(first_id, (None, None))[1] == second_id
            and nearest_parallel.get(second_id, (None, None))[1] == first_id
        )
        first_normal = _unit([
            base_fits[first_id]["normal"][0], base_fits[first_id]["normal"][2]
        ])
        second_normal = _unit([
            base_fits[second_id]["normal"][0], base_fits[second_id]["normal"][2]
        ])
        parallel = abs(float(first_normal @ second_normal)) >= math.cos(
            thresholds["angle_rad"])
        required_slices = max(3, math.floor(len(by_slice) * 0.05))
        if not mutually_nearest:
            if not parallel and len(evidence["slices"]) >= required_slices:
                bridged_adjacencies[neighbor_ids].extend(evidence["points"])
            continue
        members = [
            (index, unassigned_fits[index])
            for index in evidence["fits"]
            if index not in used_fits
        ]
        if not members:
            continue

        # One gap can contain mouldings and balcony edges. Cluster by free line
        # direction and retain the orientation with the strongest vertical support.
        parent = list(range(len(members)))

        def find(index):
            while parent[index] != index:
                parent[index] = parent[parent[index]]
                index = parent[index]
            return index

        for first in range(len(members)):
            for second in range(first + 1, len(members)):
                similarity = abs(float(
                    members[first][1]["normal"] @ members[second][1]["normal"]
                ))
                if similarity >= math.cos(thresholds["angle_rad"]):
                    parent[find(second)] = find(first)
        clusters = defaultdict(list)
        for position, member in enumerate(members):
            clusters[find(position)].append(member)

        ranked = []
        for cluster in clusters.values():
            observations = [
                observation
                for _, fit in cluster
                for observation in fit["observations"]
            ]
            slices = {observation["slice"] for observation in observations}
            support = sum(
                observation["length"] * thresholds["step"]
                for observation in observations
            )
            ranked.append((len(slices), support, cluster, observations))
        slice_count, _, cluster, observations = max(ranked, key=lambda item: item[:2])
        if slice_count < required_slices:
            continue
        fitted = _fit_track(observations)
        if fitted is None or fitted["rms"] > thresholds["line_distance"] * 4.0:
            continue
        fitted["id"] = len(base_fits) + len(supplemental)
        fitted["source_tracks"] = set().union(*(
            fit["source_tracks"] for _, fit in cluster
        ))
        fitted["mesh_plane_id"] = None
        fitted["mesh_component_index"] = 0
        fitted["mesh_component_count"] = 1
        fitted["mesh_support_area"] = 0.0
        neighbor_bounds = [
            base_fits[neighbor_id].get("mesh_support_bounds") or {}
            for neighbor_id in neighbor_ids
        ]
        y_mins = [bounds["y_min"] for bounds in neighbor_bounds if "y_min" in bounds]
        y_maxs = [bounds["y_max"] for bounds in neighbor_bounds if "y_max" in bounds]
        fitted["mesh_support_bounds"] = {
            **({"y_min": min(y_mins)} if y_mins else {}),
            **({"y_max": max(y_maxs)} if y_maxs else {}),
        }
        fitted["slice_support_area"] = sum(
            observation["length"] * thresholds["step"]
            for observation in observations
        )
        fitted["gap_neighbors"] = neighbor_ids
        supplemental.append(fitted)
        used_fits.update(index for index, _ in cluster)
    if return_bridged_adjacencies:
        return supplemental, bridged_adjacencies
    return supplemental


def _anchor_component(members, candidate, thresholds, component_index,
                      component_count, output_id):
    observations = [
        observation
        for fit, _ in members
        for observation in fit["observations"]
    ]
    fitted = _fit_track(observations)
    if fitted is None:
        return None
    normal = _unit(np.asarray(candidate["normal"], dtype=float))
    # Bounds aggregated from disconnected CGAL regions cannot delimit one
    # component. In that case the slice component supplies its own extents.
    support_bounds = (
        candidate.get("support_bounds") if component_count == 1 else None
    )
    if float(normal @ fitted["normal"]) < 0.0:
        normal = -normal
        if support_bounds:
            support_bounds = {
                **support_bounds,
                "t_min": -float(support_bounds["t_max"]),
                "t_max": -float(support_bounds["t_min"]),
            }
    candidate_point = np.asarray(candidate["point"], dtype=float)
    fitted["center"] = fitted["center"] - (
        (fitted["center"] - candidate_point) @ normal
    ) * normal
    fitted["normal"] = normal
    fitted["rms"] = max(
        fitted["rms"], float(candidate.get("rms") or 0.0))
    fitted["id"] = output_id
    fitted["mesh_plane_id"] = candidate["id"]
    fitted["mesh_component_index"] = component_index
    fitted["mesh_component_count"] = component_count
    fitted["mesh_support_area"] = (
        float(candidate.get("area_m2") or 0.0) / component_count
    )
    fitted["mesh_support_bounds"] = support_bounds
    fitted["source_tracks"] = set().union(*(
        fit["source_tracks"] for fit, _ in members
    ))
    fitted["slice_support_area"] = sum(
        observation["length"] * thresholds["step"]
        for observation in observations
    )
    return fitted


def observed_adjacencies(by_slice, track_to_fit):
    evidence = defaultdict(list)
    for observations in by_slice:
        groups = defaultdict(list)
        for observation in observations:
            groups[observation["contour"]].append(observation)
        for contour in groups.values():
            contour.sort(key=lambda item: item["order"])
            for first, second in zip(contour, contour[1:]):
                a = track_to_fit.get(first["track"])
                b = track_to_fit.get(second["track"])
                if a is None or b is None or a == b:
                    continue
                if np.linalg.norm(_xz(first["b"]) - _xz(second["a"])) > 1e-5:
                    continue
                key = tuple(sorted((a, b)))
                evidence[key].append((first["b"], first["slice"]))
    return evidence


def infer_support_adjacencies(fits, thresholds):
    """Recover corners hidden by short untracked detail segments.

    Two planes are neighbours only when their mathematical intersection is
    repeatedly approached by endpoints from both supports at the same heights.
    Merely intersecting somewhere in space is insufficient.
    """
    evidence = defaultdict(list)
    per_fit_slice = []
    for fit in fits:
        grouped = defaultdict(list)
        for observation in fit["observations"]:
            grouped[observation["slice"]].append(observation)
        per_fit_slice.append(grouped)

    for first_id, first in enumerate(fits):
        first_normal = _unit([first["normal"][0], first["normal"][2]])
        first_offset = float(_xz(first["center"]) @ first_normal)
        for second_id in range(first_id + 1, len(fits)):
            second = fits[second_id]
            second_normal = _unit([second["normal"][0], second["normal"][2]])
            matrix = np.asarray([first_normal, second_normal])
            if abs(float(np.linalg.det(matrix))) <= math.sin(thresholds["angle_rad"]):
                continue
            second_offset = float(_xz(second["center"]) @ second_normal)
            intersection = np.linalg.solve(
                matrix, np.asarray([first_offset, second_offset]))
            common_slices = set(per_fit_slice[first_id]) & set(per_fit_slice[second_id])
            for slice_id in common_slices:
                first_distance = min(
                    float(np.linalg.norm(_xz(point) - intersection))
                    for observation in per_fit_slice[first_id][slice_id]
                    for point in (observation["a"], observation["b"])
                )
                second_distance = min(
                    float(np.linalg.norm(_xz(point) - intersection))
                    for observation in per_fit_slice[second_id][slice_id]
                    for point in (observation["a"], observation["b"])
                )
                if max(first_distance, second_distance) <= thresholds["tangent_gap"]:
                    y = per_fit_slice[first_id][slice_id][0]["y"]
                    evidence[(first_id, second_id)].append((
                        [float(intersection[0]), float(y), float(intersection[1])],
                        slice_id,
                    ))
    return evidence


def _weighted_quantile(values, quantile):
    values = np.sort(np.asarray(values, dtype=float))
    if len(values) == 0:
        return 0.0
    return float(np.quantile(values, quantile))


def _horizontal_plane(fit, extrusion, reference_y):
    normal = fit["normal"]
    horizontal = _unit([normal[0], normal[2]])
    regularized_normal = _unit([
        horizontal[0],
        -(horizontal[0] * extrusion[0] + horizontal[1] * extrusion[2]) / extrusion[1],
        horizontal[1],
    ])
    center = fit["center"]
    direction = _unit([horizontal[1], -horizontal[0]])
    offset = float(_xz(center) @ horizontal)
    return {
        **fit,
        "normal": regularized_normal,
        "horizontal_normal": horizontal,
        "direction": direction,
        "offset": offset,
        "reference_y": reference_y,
    }


def _intersection_xz(first, second):
    matrix = np.asarray([first["horizontal_normal"], second["horizontal_normal"]])
    determinant = float(np.linalg.det(matrix))
    if abs(determinant) <= math.sin(math.radians(2.0)):
        return None
    return np.linalg.solve(matrix, np.asarray([first["offset"], second["offset"]]))


def build_open_planes(fits, adjacencies, thresholds):
    if not fits:
        return []
    source_planes = [{
        "normal": fit["normal"].tolist(),
        "fit_weight": fit["support_area"],
        "type": "surface",
    } for fit in fits]
    extrusion = np.asarray(estimate_common_extrusion(source_planes), dtype=float)
    reference_y = float(np.median([
        observation["y"] for fit in fits for observation in fit["observations"]
    ]))
    planes = [_horizontal_plane(fit, extrusion, reference_y) for fit in fits]

    extents = []
    for plane in planes:
        tangents = []
        ys = []
        for observation in plane["observations"]:
            tangents.extend(float(_xz(point) @ plane["direction"])
                            for point in (observation["a"], observation["b"]))
            ys.append(observation["y"])
        extents.append({
            "t_min": min(
                _weighted_quantile(tangents, 0.02),
                float((plane.get("mesh_support_bounds") or {}).get(
                    "t_min", float("inf"))),
            ),
            "t_max": max(
                _weighted_quantile(tangents, 0.98),
                float((plane.get("mesh_support_bounds") or {}).get(
                    "t_max", float("-inf"))),
            ),
            "y_min": min(
                min(ys) - thresholds["step"] * 0.5,
                float((plane.get("mesh_support_bounds") or {}).get(
                    "y_min", float("inf"))),
            ),
            "y_max": max(
                max(ys) + thresholds["step"] * 0.5,
                float((plane.get("mesh_support_bounds") or {}).get(
                    "y_max", float("-inf"))),
            ),
            "snaps": {},
        })

    # Only observed neighbours may create a shared edge. This prevents remote
    # intersections between unrelated planes from growing into infinite panels.
    accepted_pairs = set()
    for (first_id, second_id), evidence in adjacencies.items():
        if first_id >= len(planes) or second_id >= len(planes):
            continue
        required = max(2, math.ceil(min(
            len(planes[first_id]["slice_ids"]), len(planes[second_id]["slice_ids"])
        ) * 0.15))
        if len({slice_id for _, slice_id in evidence}) < required:
            continue
        intersection = _intersection_xz(planes[first_id], planes[second_id])
        if intersection is None:
            continue
        accepted_pairs.add((first_id, second_id))
        observed = np.asarray([_xz(point) for point, _ in evidence])
        residual = float(np.median(np.linalg.norm(observed - intersection, axis=1)))
        for plane_id, other_id in ((first_id, second_id), (second_id, first_id)):
            plane, extent = planes[plane_id], extents[plane_id]
            tangent = float(intersection @ plane["direction"])
            side = "min" if abs(tangent - extent["t_min"]) <= abs(tangent - extent["t_max"]) else "max"
            width = max(extent["t_max"] - extent["t_min"], thresholds["min_segment"])
            if min(abs(tangent - extent["t_min"]), abs(tangent - extent["t_max"])) > width * 0.45:
                continue
            old = extent["snaps"].get(side)
            candidate = (len(evidence), -residual, tangent, intersection, other_id)
            if old is None or candidate[:2] > old[:2]:
                extent["snaps"][side] = candidate

    # Fill corners hidden by facade detail using mutual-nearest topology. An
    # intersection is accepted only if each plane independently chooses the other
    # as the closest continuation of that endpoint. This rejects unrelated planes
    # without assuming a facade count or a metric gap threshold.
    nearest = {}
    pair_candidates = []
    for first_id, first in enumerate(planes):
        for second_id in range(first_id + 1, len(planes)):
            second = planes[second_id]
            intersection = _intersection_xz(first, second)
            if intersection is None:
                continue
            endpoints = []
            valid = True
            for plane_id, plane in ((first_id, first), (second_id, second)):
                extent = extents[plane_id]
                tangent = float(intersection @ plane["direction"])
                distances = {
                    "min": abs(tangent - extent["t_min"]),
                    "max": abs(tangent - extent["t_max"]),
                }
                side = min(distances, key=distances.get)
                width = max(extent["t_max"] - extent["t_min"], EPS)
                normalized_distance = distances[side] / width
                if normalized_distance > 0.50:
                    valid = False
                    break
                endpoints.append((plane_id, side, tangent, normalized_distance))
            if not valid:
                continue
            pair_candidates.append((first_id, second_id, intersection, endpoints))
            for plane_id, side, tangent, normalized_distance in endpoints:
                key = (plane_id, side)
                current = nearest.get(key)
                value = (normalized_distance,
                         second_id if plane_id == first_id else first_id,
                         tangent, intersection)
                if current is None or value[0] < current[0]:
                    nearest[key] = value

    mutual_pairs = []
    for first_id, second_id, intersection, endpoints in pair_candidates:
        first_endpoint, second_endpoint = endpoints
        first_choice = nearest.get((first_endpoint[0], first_endpoint[1]))
        second_choice = nearest.get((second_endpoint[0], second_endpoint[1]))
        if (first_choice is None or second_choice is None
                or first_choice[1] != second_id or second_choice[1] != first_id):
            continue
        mutual_pairs.append((first_id, second_id))
        for plane_id, side, tangent, normalized_distance in endpoints:
            if side in extents[plane_id]["snaps"]:
                continue
            extents[plane_id]["snaps"][side] = (
                1, -normalized_distance, tangent, intersection,
                second_id if plane_id == first_id else first_id,
            )

    topology_pairs = accepted_pairs | set(mutual_pairs)
    vertical_tolerance = max(thresholds["step"], thresholds["noise"] * 3.0)
    for first_id, second_id in topology_pairs:
        first, second = extents[first_id], extents[second_id]
        if abs(first["y_min"] - second["y_min"]) <= vertical_tolerance:
            shared = min(first["y_min"], second["y_min"])
            first["y_min"] = second["y_min"] = shared
        if abs(first["y_max"] - second["y_max"]) <= vertical_tolerance:
            shared = max(first["y_max"], second["y_max"])
            first["y_max"] = second["y_max"] = shared

    shared_neighbors = defaultdict(set)
    for first_id, second_id in topology_pairs:
        shared_neighbors[first_id].add(second_id)
        shared_neighbors[second_id].add(first_id)

    output = []
    for plane_id, (plane, extent) in enumerate(zip(planes, extents)):
        for side, candidate in extent["snaps"].items():
            extent[f"t_{side}"] = candidate[2]
        if extent["t_max"] <= extent["t_min"] + EPS:
            continue

        def point(tangent, y):
            base_xz = plane["direction"] * tangent + plane["horizontal_normal"] * plane["offset"]
            amount = (y - reference_y) / extrusion[1]
            return [
                float(base_xz[0] + extrusion[0] * amount),
                float(y),
                float(base_xz[1] + extrusion[2] * amount),
            ]

        corners = [
            point(extent["t_min"], extent["y_min"]),
            point(extent["t_max"], extent["y_min"]),
            point(extent["t_max"], extent["y_max"]),
            point(extent["t_min"], extent["y_max"]),
        ]
        width = float(np.linalg.norm(np.asarray(corners[1]) - corners[0]))
        height = float(np.linalg.norm(np.asarray(corners[3]) - corners[0]))
        output.append({
            "id": plane["id"],
            "nome": f"Superficie {plane['id'] + 1}",
            "tipo": "surface",
            "punto": np.mean(np.asarray(corners), axis=0).tolist(),
            "normale": plane["normal"].tolist(),
            "corners": corners,
            "area_m2": width * height,
            "tri_area_m2": width * height,
            "coverage": 1.0,
            "fill_ratio": 1.0,
            "rms_m": plane["rms"],
            "score": len(plane["slice_ids"]),
            "fit_mode": "multi_slice_free_orientation",
            "fit_samples": len(plane["observations"]),
            "extrusion_direction": extrusion.tolist(),
            "regularization": "observed_adjacency_open_surface",
            "source_tracks": sorted(plane["source_tracks"]),
            "mesh_plane_id": plane.get("mesh_plane_id"),
            "mesh_component_index": plane.get("mesh_component_index"),
            "mesh_component_count": plane.get("mesh_component_count"),
            "mesh_support_area": plane.get("mesh_support_area"),
            "slice_support_area": plane.get("slice_support_area"),
            "shared_neighbors": sorted(shared_neighbors[plane_id]),
            "w": width,
            "h": height,
            "n_triangoli": 2,
        })
    return classify_final_plane_types(output)


def reconstruct(stack, candidates_path=None):
    thresholds = derive_thresholds(stack)
    by_slice = extract_segments(stack, thresholds)
    tracks = track_segments(by_slice, thresholds)
    fits = persistent_fits(tracks, thresholds)
    merged = merge_coplanar_fits(fits, thresholds)
    if candidates_path:
        base_fits, unassigned = anchor_fits_to_mesh_planes(
            merged, candidates_path, thresholds, return_unassigned=True)
        supplemental, bridged_adjacencies = discover_gap_fits(
            by_slice, base_fits, unassigned, thresholds,
            return_bridged_adjacencies=True)
        merged = base_fits + supplemental
    else:
        bridged_adjacencies = {}
    track_to_fit = {
        track_id: fit["id"]
        for fit in merged
        for track_id in fit["source_tracks"]
    }
    adjacencies = observed_adjacencies(by_slice, track_to_fit)
    for key, values in bridged_adjacencies.items():
        adjacencies[key].extend(values)
    inferred = infer_support_adjacencies(merged, thresholds)
    for key, values in inferred.items():
        adjacencies[key].extend(values)
    planes = build_open_planes(merged, adjacencies, thresholds)
    return {
        "planes": planes,
        "source": {
            "plane_mode": "multi_slice_open_surface",
            "edge_mode": "observed_or_mutual_nearest_intersections",
            "tracks_total": len(tracks),
            "tracks_persistent": len(fits),
            "planes_merged": len(merged),
            "mesh_support": bool(candidates_path),
            "adjacencies": len(adjacencies),
            "shared_edges": sum(
                len(plane.get("shared_neighbors", [])) for plane in planes
            ) // 2,
            "thresholds": {
                key: (math.degrees(value) if key == "angle_rad" else value)
                for key, value in thresholds.items()
            },
        },
    }


def run(stack_path, out_dir, viewer_bundle=None, candidates_path=None):
    stack_path = Path(stack_path)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    with open(stack_path) as source:
        stack = json.load(source)
    result = reconstruct(stack, candidates_path=candidates_path)
    with open(out_dir / "fused_planes.json", "w") as output:
        json.dump(result, output, separators=(",", ":"))
    if viewer_bundle:
        viewer_data = {**result, "mesh": stack["mesh"]}
        write_viewer(out_dir, viewer_data, viewer_bundle)
    print(json.dumps({
        "planes": len(result["planes"]),
        **result["source"],
        "out": str(out_dir),
    }))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--viewer-bundle")
    parser.add_argument("--candidates",
                        help="regioni planari CGAL usate come evidenza 3D")
    args = parser.parse_args()
    run(args.stack, args.out_dir, args.viewer_bundle, args.candidates)


if __name__ == "__main__":
    main()
