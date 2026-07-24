#!/usr/bin/env python3
"""Detect persistent planar structures on a raw Object Capture mesh.

The mesh is never repaired or modified. Vertices and OBJ normals are voxelized
deterministically, CGAL region growing is run at three neighborhood scales, and
regions are associated through their shared input samples. The output is a
diagnostic candidate set, not final facade topology.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import shutil
import struct
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[2]
LOCAL_BINARY = ROOT / "tools/cgal_multiscale_planes/build/cgal_multiscale_planes"
DEFAULT_BINARY = Path(os.environ.get(
    "ACRO_MULTISCALE_PLANES_BIN",
    "/usr/local/bin/acro-multiscale-planes" if Path("/usr/local/bin/acro-multiscale-planes").exists()
    else str(LOCAL_BINARY),
))


@dataclass(frozen=True)
class Scale:
    name: str
    k: int
    distance_factor: float
    angle: float
    min_region: int


SCALES = (
    Scale("fine", 12, 1.5, 9.0, 90),
    Scale("medium", 24, 3.0, 13.0, 150),
    Scale("structural", 48, 6.0, 18.0, 240),
)


def _unit(values: np.ndarray) -> np.ndarray:
    lengths = np.linalg.norm(values, axis=-1, keepdims=True)
    return values / np.maximum(lengths, 1e-12)


def _obj_index(value: str, size: int) -> int:
    index = int(value)
    return index - 1 if index > 0 else size + index


def load_obj_samples(
    path: Path,
) -> tuple[np.ndarray, np.ndarray, float, np.ndarray, np.ndarray]:
    """Read vertices and corner normals, plus a sampled median mesh edge."""
    vertices: list[tuple[float, float, float]] = []
    source_normals: list[tuple[float, float, float]] = []
    faces: list[list[tuple[int, int | None]]] = []
    with path.open("r", errors="replace") as source:
        for line in source:
            if line.startswith("v "):
                values = line.split()
                vertices.append(tuple(map(float, values[1:4])))
            elif line.startswith("vn "):
                values = line.split()
                source_normals.append(tuple(map(float, values[1:4])))
            elif line.startswith("f "):
                corners = []
                for token in line.split()[1:]:
                    fields = token.split("/")
                    vertex = _obj_index(fields[0], len(vertices))
                    normal = None
                    if len(fields) >= 3 and fields[2]:
                        normal = _obj_index(fields[2], len(source_normals))
                    corners.append((vertex, normal))
                if len(corners) >= 3:
                    for offset in range(1, len(corners) - 1):
                        faces.append([corners[0], corners[offset], corners[offset + 1]])

    mesh_vertices = np.asarray(vertices, dtype=np.float64)
    mesh_faces = np.asarray(
        [[corner[0] for corner in face] for face in faces],
        dtype=np.int32,
    )
    points = mesh_vertices
    normals_in = np.asarray(source_normals, dtype=np.float64)
    normal_sum = np.zeros_like(points)
    edge_samples = []
    for face_index, face in enumerate(faces):
        vertex_ids = [corner[0] for corner in face]
        triangle = points[vertex_ids]
        geometric = np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
        geometric_length = float(np.linalg.norm(geometric))
        geometric = geometric / geometric_length if geometric_length > 1e-12 else np.zeros(3)
        for vertex_id, normal_id in face:
            if normal_id is not None and 0 <= normal_id < len(normals_in):
                normal_sum[vertex_id] += normals_in[normal_id]
            else:
                normal_sum[vertex_id] += geometric
        if face_index % 10 == 0:
            edge_samples.extend((
                float(np.linalg.norm(triangle[1] - triangle[0])),
                float(np.linalg.norm(triangle[2] - triangle[1])),
                float(np.linalg.norm(triangle[0] - triangle[2])),
            ))

    normals = _unit(normal_sum)
    valid = np.linalg.norm(normal_sum, axis=1) > 1e-10
    points = points[valid]
    normals = normals[valid]
    positive_edges = np.asarray([value for value in edge_samples if value > 1e-9])
    if positive_edges.size == 0:
        raise RuntimeError("La mesh non contiene spigoli validi")
    return points, normals, float(np.median(positive_edges)), mesh_vertices, mesh_faces


def voxelize(points: np.ndarray, normals: np.ndarray, voxel: float) -> tuple[np.ndarray, np.ndarray]:
    origin = points.min(axis=0)
    keys = np.floor((points - origin) / voxel).astype(np.int64)
    order = np.lexsort((keys[:, 2], keys[:, 1], keys[:, 0]))
    sorted_keys = keys[order]
    starts = np.r_[0, np.flatnonzero(np.any(np.diff(sorted_keys, axis=0), axis=1)) + 1]
    counts = np.diff(np.r_[starts, len(order)]).astype(np.float64)
    sampled_points = np.add.reduceat(points[order], starts, axis=0) / counts[:, None]
    sampled_normals = _unit(np.add.reduceat(normals[order], starts, axis=0))
    valid = np.linalg.norm(sampled_normals, axis=1) > 0.5
    return sampled_points[valid], sampled_normals[valid]


def write_point_set(path: Path, points: np.ndarray, normals: np.ndarray) -> None:
    with path.open("w") as output:
        output.write("ply\nformat ascii 1.0\n")
        output.write(f"element vertex {len(points)}\n")
        for name in ("x", "y", "z", "nx", "ny", "nz"):
            output.write(f"property double {name}\n")
        output.write("end_header\n")
        for point, normal in zip(points, normals):
            output.write(
                f"{point[0]:.10g} {point[1]:.10g} {point[2]:.10g} "
                f"{normal[0]:.10g} {normal[1]:.10g} {normal[2]:.10g}\n"
            )


def read_regions(path: Path, scale: Scale, max_distance: float) -> list[dict]:
    rows = []
    with path.open(newline="") as source:
        for row in csv.DictReader(source):
            rows.append({
                "scale": scale.name,
                "region": int(row["region"]),
                "npoints": int(row["npoints"]),
                "normal": np.asarray([row["nx"], row["ny"], row["nz"]], dtype=float),
                "d": float(row["d"]),
                "center": np.asarray([row["cx"], row["cy"], row["cz"]], dtype=float),
                "rms": float(row["rms"]),
                "max_distance": max_distance,
            })
    return rows


def read_labels(path: Path) -> np.ndarray:
    return np.loadtxt(path, delimiter=",", skiprows=1, usecols=1, dtype=np.int64)


class DisjointSet:
    def __init__(self, size: int):
        self.parent = list(range(size))

    def find(self, item: int) -> int:
        while self.parent[item] != item:
            self.parent[item] = self.parent[self.parent[item]]
            item = self.parent[item]
        return item

    def union(self, left: int, right: int) -> None:
        left, right = self.find(left), self.find(right)
        if left != right:
            self.parent[right] = left


def associate_regions(all_regions: list[list[dict]], labels: list[np.ndarray]) -> list[list[dict]]:
    nodes = [region for regions in all_regions for region in regions]
    node_index = {(node["scale"], node["region"]): index for index, node in enumerate(nodes)}
    regions_by_id = [
        {region["region"]: region for region in regions}
        for regions in all_regions
    ]
    sets = DisjointSet(len(nodes))
    cosine_limit = math.cos(math.radians(12.0))

    for left_scale in range(len(labels)):
        for right_scale in range(left_scale + 1, len(labels)):
            left_labels, right_labels = labels[left_scale], labels[right_scale]
            valid = (left_labels >= 0) & (right_labels >= 0)
            pairs = np.stack((left_labels[valid], right_labels[valid]), axis=1)
            if not len(pairs):
                continue
            unique_pairs, overlap = np.unique(pairs, axis=0, return_counts=True)
            for pair, common in zip(unique_pairs, overlap):
                left = regions_by_id[left_scale].get(int(pair[0]))
                right = regions_by_id[right_scale].get(int(pair[1]))
                if left is None or right is None:
                    continue
                coverage = common / max(1, min(left["npoints"], right["npoints"]))
                if coverage < 0.08:
                    continue
                alignment = abs(float(left["normal"] @ right["normal"]))
                if alignment < cosine_limit:
                    continue
                right_normal = right["normal"] if float(left["normal"] @ right["normal"]) >= 0 else -right["normal"]
                right_d = right["d"] if float(left["normal"] @ right["normal"]) >= 0 else -right["d"]
                offset = abs(float(left["d"] - right_d))
                if offset > 2.5 * max(left["max_distance"], right["max_distance"]):
                    continue
                sets.union(
                    node_index[(left["scale"], left["region"])],
                    node_index[(right["scale"], right["region"])],
                )

    groups: dict[int, list[dict]] = {}
    for index, node in enumerate(nodes):
        groups.setdefault(sets.find(index), []).append(node)
    return list(groups.values())


def robust_plane(points: np.ndarray, preferred_normal: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    weights = np.ones(len(points), dtype=np.float64)
    center = np.median(points, axis=0)
    normal = _unit(preferred_normal.reshape(1, 3))[0]
    residuals = np.zeros(len(points))
    for _ in range(5):
        total = max(float(weights.sum()), 1e-12)
        center = (points * weights[:, None]).sum(axis=0) / total
        delta = points - center
        covariance = (delta * weights[:, None]).T @ delta / total
        _, vectors = np.linalg.eigh(covariance)
        fitted = vectors[:, 0]
        if float(fitted @ normal) < 0:
            fitted = -fitted
        normal = fitted
        residuals = delta @ normal
        median = float(np.median(residuals))
        mad = float(np.median(np.abs(residuals - median)))
        sigma = max(1.4826 * mad, 1e-8)
        amount = np.abs(residuals - median) / (1.5 * sigma)
        weights = np.where(amount <= 1.0, 1.0, 1.0 / np.maximum(amount, 1e-12))
    return center, _unit(normal.reshape(1, 3))[0], residuals


def plane_patch(points: np.ndarray, center: np.ndarray, normal: np.ndarray) -> tuple[list[list[float]], float, float]:
    up = np.asarray([0.0, 1.0, 0.0])
    vertical = up - normal * float(up @ normal)
    if np.linalg.norm(vertical) < 1e-6:
        vertical = np.asarray([1.0, 0.0, 0.0]) - normal * normal[0]
    v_axis = _unit(vertical.reshape(1, 3))[0]
    u_axis = _unit(np.cross(v_axis, normal).reshape(1, 3))[0]
    delta = points - center
    u = delta @ u_axis
    v = delta @ v_axis
    umin, umax = np.quantile(u, [0.01, 0.99])
    vmin, vmax = np.quantile(v, [0.01, 0.99])
    corners = [
        center + u_axis * umin + v_axis * vmin,
        center + u_axis * umax + v_axis * vmin,
        center + u_axis * umax + v_axis * vmax,
        center + u_axis * umin + v_axis * vmax,
    ]
    return [corner.tolist() for corner in corners], float(umax - umin), float(vmax - vmin)


def classify_candidate_support(
    points: np.ndarray,
    normals: np.ndarray,
    member_indices: np.ndarray,
    scale_membership: dict[str, np.ndarray],
    center: np.ndarray,
    normal: np.ndarray,
    voxel: float,
) -> dict:
    """Build a non-destructive clean-core preview for one multiscale candidate."""
    member_points = points[member_indices]
    member_normals = normals[member_indices]
    corroborated = scale_membership.get("fine", np.zeros(len(member_indices), dtype=bool))
    corroborated |= scale_membership.get("medium", np.zeros(len(member_indices), dtype=bool))
    structural = scale_membership.get("structural", np.zeros(len(member_indices), dtype=bool))

    fine_distance = voxel * 1.25
    medium_distance = voxel * 2.5
    structural_distance = voxel * 5.0
    clean_center = center.copy()
    clean_normal = normal.copy()

    for _ in range(2):
        signed = (member_points - clean_center) @ clean_normal
        median = float(np.median(signed))
        mad = float(np.median(np.abs(signed - median)))
        sigma = max(1.4826 * mad, voxel * 0.15)
        core_distance = min(medium_distance, max(fine_distance, 3.0 * sigma))
        normal_alignment = np.clip(np.abs(member_normals @ clean_normal), 0.0, 1.0)
        angles = np.degrees(np.arccos(normal_alignment))
        core = corroborated & (np.abs(signed - median) <= core_distance) & (angles <= 13.0)
        if int(core.sum()) < 40:
            break
        clean_center, clean_normal, _ = robust_plane(member_points[core], clean_normal)

    signed = (member_points - clean_center) @ clean_normal
    median = float(np.median(signed))
    mad = float(np.median(np.abs(signed - median)))
    sigma = max(1.4826 * mad, voxel * 0.15)
    core_distance = min(medium_distance, max(fine_distance, 3.0 * sigma))
    normal_alignment = np.clip(np.abs(member_normals @ clean_normal), 0.0, 1.0)
    angles = np.degrees(np.arccos(normal_alignment))
    core = corroborated & (np.abs(signed - median) <= core_distance) & (angles <= 13.0)
    attachment = ~core & (
        (np.abs(signed - median) <= structural_distance * 1.25)
        & (angles <= 22.0)
    )
    rejected = ~(core | attachment)

    if int(core.sum()) >= 4:
        clean_corners, clean_width, clean_height = plane_patch(
            member_points[core], clean_center, clean_normal
        )
        clean_residuals = (member_points[core] - clean_center) @ clean_normal
        clean_rms = float(np.sqrt(np.mean(clean_residuals * clean_residuals)))
    else:
        clean_corners, clean_width, clean_height = plane_patch(
            member_points, center, normal
        )
        clean_rms = float(np.sqrt(np.mean(signed * signed)))

    return {
        "core_points": member_indices[core].astype(int).tolist(),
        "attachment_points": member_indices[attachment].astype(int).tolist(),
        "rejected_points": member_indices[rejected].astype(int).tolist(),
        "core_count": int(core.sum()),
        "attachment_count": int(attachment.sum()),
        "rejected_count": int(rejected.sum()),
        "structural_only_count": int((structural & ~corroborated).sum()),
        "core_distance": float(core_distance),
        "clean_center": clean_center.tolist(),
        "clean_normal": clean_normal.tolist(),
        "clean_corners": clean_corners,
        "clean_width": clean_width,
        "clean_height": clean_height,
        "clean_rms": clean_rms,
    }


def build_candidates(
    groups: list[list[dict]],
    regions_by_scale: list[list[dict]],
    labels: list[np.ndarray],
    points: np.ndarray,
    normals: np.ndarray,
    voxel: float,
) -> tuple[list[dict], np.ndarray]:
    scale_positions = {scale.name: index for index, scale in enumerate(SCALES)}
    point_candidate = np.full(len(points), -1, dtype=np.int64)
    candidates = []
    span = np.ptp(points, axis=0)
    horizontal_span = float(math.hypot(span[0], span[2]))
    structural_support = max(240, int(math.ceil(len(points) * 0.004)))
    groups = sorted(groups, key=lambda group: -sum(node["npoints"] for node in group))
    for group in groups:
        mask = np.zeros(len(points), dtype=bool)
        membership = {
            scale.name: np.zeros(len(points), dtype=bool)
            for scale in SCALES
        }
        scales = set()
        normal_sum = np.zeros(3)
        for node in group:
            position = scale_positions[node["scale"]]
            region_mask = labels[position] == node["region"]
            mask |= region_mask
            membership[node["scale"]] |= region_mask
            scales.add(node["scale"])
            normal = node["normal"]
            if float(normal @ normal_sum) < 0:
                normal = -normal
            normal_sum += normal * node["npoints"]
        member_points = points[mask]
        if len(member_points) < 40:
            continue
        center, normal, residuals = robust_plane(member_points, normal_sum)
        corners, width, height = plane_patch(member_points, center, normal)
        rms = float(np.sqrt(np.mean(residuals * residuals)))
        scale_count = len(scales)
        if scale_count == 3:
            confidence = "high"
            reason = "persistente a tutte le scale"
        elif scale_count == 2:
            confidence = "medium"
            reason = "persistente a due scale"
        else:
            confidence = "low"
            reason = "osservato a una sola scala"
        verticality = abs(float(normal[1]))
        if verticality <= 0.35:
            kind = "vertical"
        elif verticality >= 0.85:
            kind = "horizontal"
        else:
            kind = "sloped"
        structural = (
            kind == "vertical"
            and scale_count >= 2
            and int(mask.sum()) >= structural_support
            and height >= float(span[1]) * 0.25
            and width >= horizontal_span * 0.025
        )
        candidate_id = len(candidates)
        selected = np.flatnonzero(mask)
        diagnostic = classify_candidate_support(
            points,
            normals,
            selected,
            {name: values[selected] for name, values in membership.items()},
            center,
            normal,
            voxel,
        )
        candidates.append({
            "id": candidate_id,
            "name": f"Piano {candidate_id + 1}",
            "kind": kind,
            "role": "structural" if structural else "detail",
            "confidence": confidence,
            "reason": reason,
            "scales": sorted(scales, key=scale_positions.get),
            "support_points": int(mask.sum()),
            "center": center.tolist(),
            "normal": normal.tolist(),
            "corners": corners,
            "width": width,
            "height": height,
            "area_bbox": width * height,
            "rms": rms,
            "rms_voxels": rms / voxel,
            "diagnostic": diagnostic,
            "source_regions": [
                {"scale": node["scale"], "region": node["region"], "points": node["npoints"]}
                for node in group
            ],
        })
        current = point_candidate[mask]
        replace = current < 0
        point_candidate[selected[replace]] = candidate_id
    return candidates, point_candidate


def color_for(index: int, confidence: str) -> tuple[int, int, int]:
    palette = (
        (0, 174, 239), (255, 122, 0), (0, 196, 140), (229, 57, 143),
        (244, 194, 13), (126, 87, 194), (39, 174, 96), (235, 87, 87),
    )
    color = palette[index % len(palette)]
    if confidence == "low":
        return tuple(int(0.45 * value + 0.55 * 130) for value in color)
    return color


def assign_plane_families(candidates: list[dict], points: np.ndarray, voxel: float) -> list[dict]:
    """Group coplanar patches without transitive offset drift."""
    families: list[dict] = []
    eligible = [
        candidate for candidate in candidates
        if candidate["kind"] == "vertical" and candidate["confidence"] != "low"
    ]
    eligible.sort(key=lambda candidate: -candidate["support_points"])
    angle_limit = math.radians(8.0)

    for candidate in eligible:
        normal = np.asarray(candidate["normal"], dtype=float)
        center = np.asarray(candidate["center"], dtype=float)
        d = -float(normal @ center)
        options = []
        for family in families:
            family_normal = np.asarray(family["normal"], dtype=float)
            family_center = np.asarray(family["center"], dtype=float)
            alignment = float(normal @ family_normal)
            aligned_normal = normal if alignment >= 0.0 else -normal
            aligned_d = d if alignment >= 0.0 else -d
            angle = math.acos(max(-1.0, min(1.0, float(aligned_normal @ family_normal))))
            if angle > angle_limit:
                continue
            offset_limit = min(
                voxel * 8.0,
                max(voxel * 3.0, 2.0 * (candidate["rms"] + family["rms"])),
            )
            offset = max(
                abs(float(family_normal @ center) + family["d"]),
                abs(float(aligned_normal @ family_center) + aligned_d),
            )
            if offset > offset_limit:
                continue
            options.append((angle / angle_limit + offset / offset_limit, family, aligned_normal, aligned_d))

        if options:
            _, family, aligned_normal, aligned_d = min(options, key=lambda item: item[0])
            family["members"].append(candidate["id"])
            family["normal_samples"].append(aligned_normal)
            family["centers"].append(center)
            family["weights"].append(candidate["support_points"])
            total = float(sum(family["weights"]))
            family["normal"] = _unit(sum(
                sample * weight
                for sample, weight in zip(family["normal_samples"], family["weights"])
            ).reshape(1, 3))[0].tolist()
            family["center"] = (sum(
                sample * weight
                for sample, weight in zip(family["centers"], family["weights"])
            ) / total).tolist()
            family["d"] = -float(
                np.asarray(family["normal"]) @ np.asarray(family["center"])
            )
            family["rms"] = float(sum(
                candidates[index]["rms"] * candidates[index]["support_points"]
                for index in family["members"]
            ) / total)
        else:
            families.append({
                "id": len(families),
                "normal": normal.tolist(),
                "center": center.tolist(),
                "d": d,
                "rms": candidate["rms"],
                "members": [candidate["id"]],
                "normal_samples": [normal],
                "centers": [center],
                "weights": [candidate["support_points"]],
            })

    span = np.ptp(points, axis=0)
    horizontal_span = float(math.hypot(span[0], span[2]))
    structural_support = max(240, int(math.ceil(len(points) * 0.004)))
    for family in families:
        corners = np.asarray([
            corner
            for member in family["members"]
            for corner in candidates[member]["corners"]
        ], dtype=float)
        normal = np.asarray(family["normal"], dtype=float)
        up = np.asarray([0.0, 1.0, 0.0])
        v_axis = _unit((up - normal * float(up @ normal)).reshape(1, 3))[0]
        u_axis = _unit(np.cross(v_axis, normal).reshape(1, 3))[0]
        horizontal_extent = float(np.ptp(corners @ u_axis))
        vertical_extent = float(np.ptp(corners @ v_axis))
        support = int(sum(candidates[index]["support_points"] for index in family["members"]))
        structural = (
            support >= structural_support
            and vertical_extent >= float(span[1]) * 0.45
            and horizontal_extent >= horizontal_span * 0.025
        )
        family.update({
            "name": f"Famiglia {family['id'] + 1}",
            "role": "structural" if structural else "detail",
            "support_points": support,
            "horizontal_extent": horizontal_extent,
            "vertical_extent": vertical_extent,
        })
        for member in family["members"]:
            candidates[member]["family_id"] = family["id"]
            candidates[member]["role"] = family["role"]
        for key in ("normal_samples", "centers", "weights"):
            del family[key]

    for candidate in candidates:
        candidate.setdefault("family_id", None)
        candidate.setdefault("role", "detail")
    return families


def _plane_axes(normal: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    up = np.asarray([0.0, 1.0, 0.0])
    vertical = _unit((up - normal * float(up @ normal)).reshape(1, 3))[0]
    horizontal = _unit(np.cross(vertical, normal).reshape(1, 3))[0]
    return horizontal, vertical


def _merge_intervals(intervals: list[tuple[float, float, float]], gap: float) -> list[list[float]]:
    if not intervals:
        return []
    ordered = sorted(intervals)
    merged = [list(ordered[0])]
    for start, end, length in ordered[1:]:
        current = merged[-1]
        if start <= current[1] + gap:
            current[1] = max(current[1], end)
            current[2] += length
        else:
            merged.append([start, end, length])
    return [[float(value) for value in interval] for interval in merged]


def _rdp_polyline(points: np.ndarray, epsilon: float) -> np.ndarray:
    if len(points) <= 2:
        return points
    keep = {0, len(points) - 1}
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        if end <= start + 1:
            continue
        first = points[start, [0, 2]]
        last = points[end, [0, 2]]
        vector = last - first
        denominator = float(vector @ vector)
        middle = points[start + 1:end, :][:, [0, 2]]
        if denominator <= 1e-12:
            distances = np.linalg.norm(middle - first, axis=1)
        else:
            parameters = np.clip(((middle - first) @ vector) / denominator, 0.0, 1.0)
            projections = first + parameters[:, None] * vector
            distances = np.linalg.norm(middle - projections, axis=1)
        if not len(distances):
            continue
        local = int(np.argmax(distances))
        if float(distances[local]) <= epsilon:
            continue
        split = start + 1 + local
        keep.add(split)
        stack.extend(((start, split), (split, end)))
    return points[sorted(keep)]


def _section_polylines(endpoints: np.ndarray, y: float, voxel: float) -> list[dict]:
    """Join triangle-plane segments into ordered, angle-preserving contours."""
    tolerance = max(voxel * 0.12, 1e-7)
    node_lookup: dict[tuple[int, int], int] = {}
    node_sums = []
    node_counts = []
    edges = []
    edge_set = set()

    def node_id(point: np.ndarray) -> int:
        key = tuple(np.rint(point[[0, 2]] / tolerance).astype(np.int64))
        existing = node_lookup.get(key)
        if existing is not None:
            node_sums[existing] += point
            node_counts[existing] += 1
            return existing
        index = len(node_sums)
        node_lookup[key] = index
        node_sums.append(point.copy())
        node_counts.append(1)
        return index

    for segment in endpoints:
        first = node_id(segment[0])
        second = node_id(segment[1])
        edge_key = tuple(sorted((first, second)))
        if first != second and edge_key not in edge_set:
            edge_set.add(edge_key)
            edges.append((first, second))
    if not edges:
        return []
    coordinates = np.asarray([
        total / count for total, count in zip(node_sums, node_counts)
    ])
    adjacency: list[list[int]] = [[] for _ in range(len(coordinates))]
    for edge_id, (first, second) in enumerate(edges):
        adjacency[first].append(edge_id)
        adjacency[second].append(edge_id)

    unused = set(range(len(edges)))
    paths = []
    while unused:
        component_edges = set()
        seed = next(iter(unused))
        frontier = [edges[seed][0], edges[seed][1]]
        component_nodes = set(frontier)
        while frontier:
            node = frontier.pop()
            for edge_id in adjacency[node]:
                if edge_id not in unused or edge_id in component_edges:
                    continue
                component_edges.add(edge_id)
                first, second = edges[edge_id]
                other = second if first == node else first
                if other not in component_nodes:
                    component_nodes.add(other)
                    frontier.append(other)
        remaining = set(component_edges)
        while remaining:
            endpoints_nodes = [
                node for node in component_nodes
                if sum(edge_id in remaining for edge_id in adjacency[node]) == 1
            ]
            current = endpoints_nodes[0] if endpoints_nodes else edges[next(iter(remaining))][0]
            ordered = [current]
            previous_vector = None
            while True:
                options = [edge_id for edge_id in adjacency[current] if edge_id in remaining]
                if not options:
                    break
                if previous_vector is not None and len(options) > 1:
                    def turn_score(edge_id: int) -> float:
                        first, second = edges[edge_id]
                        other = second if first == current else first
                        vector = coordinates[other] - coordinates[current]
                        length = np.linalg.norm(vector[[0, 2]])
                        return -float(previous_vector @ (vector[[0, 2]] / max(length, 1e-12)))
                    edge_id = min(options, key=turn_score)
                else:
                    edge_id = options[0]
                remaining.remove(edge_id)
                unused.discard(edge_id)
                first, second = edges[edge_id]
                other = second if first == current else first
                vector = coordinates[other, [0, 2]] - coordinates[current, [0, 2]]
                length = np.linalg.norm(vector)
                previous_vector = vector / max(length, 1e-12)
                current = other
                ordered.append(current)
            if len(ordered) < 2:
                continue
            points = coordinates[ordered]
            points[:, 1] = y
            simplified = _rdp_polyline(points, voxel * 1.8)
            length = float(np.linalg.norm(np.diff(points[:, [0, 2]], axis=0), axis=1).sum())
            if length >= voxel * 4.0 and len(simplified) >= 2:
                paths.append({
                    "closed": bool(ordered[0] == ordered[-1]),
                    "length": length,
                    "points": simplified.tolist(),
                })
    return sorted(paths, key=lambda item: item["length"], reverse=True)[:64]


def build_horizontal_section_evidence(
    mesh_vertices: np.ndarray,
    mesh_faces: np.ndarray,
    families: list[dict],
    voxel: float,
) -> dict:
    """Intersect the raw triangles with adaptive horizontal levels once."""
    vertical_families = [family for family in families if family.get("members")]
    if not len(mesh_faces) or not vertical_families:
        return {"step": 0.0, "levels": []}
    triangles = mesh_vertices[mesh_faces]
    y_min = float(mesh_vertices[:, 1].min())
    y_max = float(mesh_vertices[:, 1].max())
    height = max(y_max - y_min, voxel)
    step = max(voxel * 5.0, height / 96.0)
    levels = np.arange(y_min + step * 0.5, y_max, step)

    family_normals = np.asarray([family["normal"] for family in vertical_families], dtype=float)
    family_d = np.asarray([family["d"] for family in vertical_families], dtype=float)
    horizontal_axes = np.asarray([_plane_axes(normal)[0] for normal in family_normals])
    distance_limits = np.asarray([
        min(voxel * 8.0, max(voxel * 3.0, 2.0 * float(family["rms"])))
        for family in vertical_families
    ])
    cosine_limit = math.cos(math.radians(18.0))
    edge_a = np.asarray([0, 1, 2])
    edge_b = np.asarray([1, 2, 0])
    triangle_min = triangles[:, :, 1].min(axis=1)
    triangle_max = triangles[:, :, 1].max(axis=1)
    output_levels = []

    for y in levels:
        active = (triangle_min <= y) & (triangle_max > y)
        section_triangles = triangles[active]
        if not len(section_triangles):
            continue
        first = section_triangles[:, edge_a]
        second = section_triangles[:, edge_b]
        first_y = first[:, :, 1]
        second_y = second[:, :, 1]
        crossing = ((first_y <= y) & (second_y > y)) | ((second_y <= y) & (first_y > y))
        valid = crossing.sum(axis=1) == 2
        if not np.any(valid):
            continue
        first = first[valid]
        second = second[valid]
        crossing = crossing[valid]
        denominator = second[:, :, 1] - first[:, :, 1]
        parameter = np.divide(
            y - first[:, :, 1],
            denominator,
            out=np.zeros_like(denominator),
            where=np.abs(denominator) > 1e-12,
        )
        intersections = first + (second - first) * parameter[:, :, None]
        edge_order = np.argsort(~crossing, axis=1)[:, :2]
        rows = np.arange(len(intersections))[:, None]
        endpoints = intersections[rows, edge_order]
        vectors = endpoints[:, 1] - endpoints[:, 0]
        lengths = np.linalg.norm(vectors, axis=1)
        useful = lengths >= voxel * 0.35
        if not np.any(useful):
            continue
        endpoints = endpoints[useful]
        vectors = vectors[useful]
        lengths = lengths[useful]
        directions = vectors / np.maximum(lengths[:, None], 1e-12)
        midpoints = (endpoints[:, 0] + endpoints[:, 1]) * 0.5

        distances = np.abs(midpoints @ family_normals.T + family_d)
        alignment = np.abs(directions @ horizontal_axes.T)
        allowed = (distances <= distance_limits[None, :]) & (alignment >= cosine_limit)
        score = distances / distance_limits[None, :] + (1.0 - alignment) / max(1.0 - cosine_limit, 1e-6)
        score[~allowed] = np.inf
        family_intervals = {}
        for position, family in enumerate(vertical_families):
            # Keep compatible evidence for every family. Competing hypotheses may
            # be almost coplanar, so a winner-takes-all assignment would erase the
            # evidence needed to decide between them in the topology stage.
            selected = allowed[:, position]
            if not np.any(selected):
                continue
            projected = endpoints[selected] @ horizontal_axes[position]
            intervals = [
                (float(min(values)), float(max(values)), float(length))
                for values, length in zip(projected, lengths[selected])
            ]
            family_intervals[str(family["id"])] = _merge_intervals(intervals, voxel * 2.0)
        output_levels.append({
            "y": float(y),
            "families": family_intervals,
            "contours": _section_polylines(
                endpoints[np.any(allowed, axis=1)], float(y), voxel
            ),
        })
    return {"step": float(step), "levels": output_levels}


def section_continuity(
    evidence: dict,
    family_id: int,
    u_range: tuple[float, float],
    y_range: tuple[float, float],
    voxel: float,
) -> dict:
    relevant = [
        level for level in evidence.get("levels", [])
        if y_range[0] - voxel <= level["y"] <= y_range[1] + voxel
    ]
    supported = 0
    support_length = 0.0
    for level in relevant:
        found = False
        for start, end, length in level["families"].get(str(family_id), []):
            overlap = max(0.0, min(end, u_range[1]) - max(start, u_range[0]))
            if overlap >= min(voxel, max((u_range[1] - u_range[0]) * 0.05, voxel * 0.25)):
                found = True
                support_length += min(length, overlap)
        supported += int(found)
    total = len(relevant)
    return {
        "section_count": total,
        "supported_sections": supported,
        "continuity_ratio": float(supported / total) if total else 0.0,
        "support_length": float(support_length),
    }


def _family_bounds(family: dict, candidates: list[dict]) -> dict:
    normal = np.asarray(family["normal"], dtype=float)
    horizontal, _ = _plane_axes(normal)
    corners = np.asarray([
        corner
        for member_id in family["members"]
        for corner in candidates[member_id].get("diagnostic", {}).get(
            "clean_corners", candidates[member_id]["corners"]
        )
    ], dtype=float)
    projected = corners @ horizontal
    return {
        "horizontal": horizontal,
        "u_min": float(projected.min()),
        "u_max": float(projected.max()),
        "y_min": float(corners[:, 1].min()),
        "y_max": float(corners[:, 1].max()),
    }


def _plane_intersection_at_y(first: dict, second: dict, y: float) -> np.ndarray | None:
    first_normal = np.asarray(first["normal"], dtype=float)
    second_normal = np.asarray(second["normal"], dtype=float)
    matrix = np.asarray([
        [first_normal[0], first_normal[2]],
        [second_normal[0], second_normal[2]],
    ])
    determinant = float(np.linalg.det(matrix))
    if abs(determinant) < 1e-7:
        return None
    rhs = np.asarray([
        -float(first["d"]) - first_normal[1] * y,
        -float(second["d"]) - second_normal[1] * y,
    ])
    x, z = np.linalg.solve(matrix, rhs)
    return np.asarray([x, y, z], dtype=float)


def _family_persistence(evidence: dict, family_id: int, bounds: dict) -> dict:
    relevant = [
        level for level in evidence.get("levels", [])
        if bounds["y_min"] <= level["y"] <= bounds["y_max"]
    ]
    supported = sum(bool(level["families"].get(str(family_id))) for level in relevant)
    return {
        "section_count": len(relevant),
        "supported_sections": supported,
        "ratio": float(supported / len(relevant)) if relevant else 0.0,
    }


def _junction_metrics(
    first: dict,
    second: dict,
    first_bounds: dict,
    second_bounds: dict,
    evidence: dict,
    voxel: float,
) -> dict | None:
    first_normal = np.asarray(first["normal"], dtype=float)
    second_normal = np.asarray(second["normal"], dtype=float)
    angle = math.degrees(math.acos(np.clip(abs(float(first_normal @ second_normal)), 0.0, 1.0)))
    if angle < 12.0:
        return None
    y_min = max(first_bounds["y_min"], second_bounds["y_min"])
    y_max = min(first_bounds["y_max"], second_bounds["y_max"])
    if y_max <= y_min:
        return None
    first_height = max(first_bounds["y_max"] - first_bounds["y_min"], voxel)
    second_height = max(second_bounds["y_max"] - second_bounds["y_min"], voxel)
    vertical_overlap = (y_max - y_min) / max(min(first_height, second_height), voxel)
    if vertical_overlap < 0.25:
        return None

    tolerance = voxel * 3.5
    relevant = [
        level for level in evidence.get("levels", [])
        if y_min - voxel <= level["y"] <= y_max + voxel
    ]
    supported = 0
    first_distances = []
    second_distances = []
    for level in relevant:
        point = _plane_intersection_at_y(first, second, float(level["y"]))
        if point is None:
            continue
        first_u = float(point @ first_bounds["horizontal"])
        second_u = float(point @ second_bounds["horizontal"])
        first_intervals = level["families"].get(str(first["id"]), [])
        second_intervals = level["families"].get(str(second["id"]), [])
        first_distance = min(
            (min(abs(first_u - interval[0]), abs(first_u - interval[1])) for interval in first_intervals),
            default=float("inf"),
        )
        second_distance = min(
            (min(abs(second_u - interval[0]), abs(second_u - interval[1])) for interval in second_intervals),
            default=float("inf"),
        )
        if np.isfinite(first_distance):
            first_distances.append(first_distance)
        if np.isfinite(second_distance):
            second_distances.append(second_distance)
        supported += int(first_distance <= tolerance and second_distance <= tolerance)
    ratio = float(supported / len(relevant)) if relevant else 0.0
    if supported < 2 or ratio < 0.30:
        return None

    midpoint = _plane_intersection_at_y(first, second, (y_min + y_max) * 0.5)
    bottom = _plane_intersection_at_y(first, second, y_min)
    top = _plane_intersection_at_y(first, second, y_max)
    if midpoint is None or bottom is None or top is None:
        return None
    first_u = float(midpoint @ first_bounds["horizontal"])
    second_u = float(midpoint @ second_bounds["horizontal"])
    first_side = "min" if abs(first_u - first_bounds["u_min"]) <= abs(first_u - first_bounds["u_max"]) else "max"
    second_side = "min" if abs(second_u - second_bounds["u_min"]) <= abs(second_u - second_bounds["u_max"]) else "max"
    return {
        "angle": angle,
        "vertical_overlap": vertical_overlap,
        "section_count": len(relevant),
        "supported_sections": supported,
        "junction_ratio": ratio,
        "median_endpoint_gap": float(max(
            np.median(first_distances) if first_distances else float("inf"),
            np.median(second_distances) if second_distances else float("inf"),
        )),
        "y_range": [y_min, y_max],
        "line": [bottom.tolist(), top.tolist()],
        "sides": {str(first["id"]): first_side, str(second["id"]): second_side},
        "snap_limit": tolerance,
    }


def classify_envelope_roles(
    candidates: list[dict],
    families: list[dict],
    section_evidence: dict,
    voxel: float,
) -> list[dict]:
    """Promote persistent contour-closing returns without global size gates."""
    if not families:
        return []
    family_by_id = {family["id"]: family for family in families}
    bounds = {family["id"]: _family_bounds(family, candidates) for family in families}
    persistence = {
        family["id"]: _family_persistence(section_evidence, family["id"], bounds[family["id"]])
        for family in families
    }
    structural_ids = {family["id"] for family in families if family.get("role") == "structural"}
    if not structural_ids:
        structural_ids.add(max(families, key=lambda item: item.get("support_points", 0))["id"])
    dominant = max(
        (family for family in families if family["id"] in structural_ids),
        key=lambda item: item.get("support_points", 0),
    )
    envelope_y_min = min(bounds[family_id]["y_min"] for family_id in structural_ids)
    envelope_y_max = max(bounds[family_id]["y_max"] for family_id in structural_ids)
    envelope_height = max(envelope_y_max - envelope_y_min, voxel)
    dominant_normal = np.asarray(dominant["normal"], dtype=float)
    for family in families:
        family["envelope_role"] = "detail"
        family["section_persistence"] = persistence[family["id"]]
        family["envelope_height_ratio"] = float(
            (bounds[family["id"]]["y_max"] - bounds[family["id"]]["y_min"])
            / envelope_height
        )
        if family["id"] in structural_ids:
            angle = math.degrees(math.acos(np.clip(abs(float(
                np.asarray(family["normal"], dtype=float) @ dominant_normal
            )), 0.0, 1.0)))
            family["envelope_role"] = "main" if angle < 12.0 else "return"

    promotion_edges: dict[tuple[int, int], dict] = {}
    changed = True
    while changed:
        changed = False
        for family in families:
            if family["id"] in structural_ids:
                continue
            family_persistence = persistence[family["id"]]
            if family_persistence["supported_sections"] < 3 or family_persistence["ratio"] < 0.45:
                continue
            if family["envelope_height_ratio"] < 0.55:
                continue
            options = []
            for structural_id in structural_ids:
                structural = family_by_id[structural_id]
                metrics = _junction_metrics(
                    family, structural,
                    bounds[family["id"]], bounds[structural_id],
                    section_evidence, voxel,
                )
                if metrics is None:
                    continue
                score = (
                    0.35 * family_persistence["ratio"]
                    + 0.35 * metrics["junction_ratio"]
                    + 0.30 * min(1.0, metrics["vertical_overlap"])
                )
                options.append((score, structural, metrics))
            if not options:
                continue
            score, structural, metrics = max(options, key=lambda item: item[0])
            structural_ids.add(family["id"])
            family["role"] = "structural"
            family["envelope_role"] = "return"
            family["promotion"] = {
                "reason": "persistent_contour_junction",
                "reference_family_id": structural["id"],
                "score": score,
                "metrics": metrics,
            }
            for member_id in family["members"]:
                candidates[member_id]["role"] = "structural"
                candidates[member_id]["envelope_role"] = "return"
            promotion_edges[tuple(sorted((family["id"], structural["id"])))] = metrics
            changed = True

    for family in families:
        for member_id in family["members"]:
            candidates[member_id]["envelope_role"] = family["envelope_role"]

    junctions = []
    envelope = [family for family in families if family["id"] in structural_ids]
    for position, first in enumerate(envelope):
        for second in envelope[position + 1:]:
            key = tuple(sorted((first["id"], second["id"])))
            metrics = promotion_edges.get(key) or _junction_metrics(
                first, second,
                bounds[first["id"]], bounds[second["id"]],
                section_evidence, voxel,
            )
            if metrics is None:
                continue
            junctions.append({
                "id": len(junctions),
                "families": [first["id"], second["id"]],
                "status": "accepted",
                "confidence": "high" if metrics["junction_ratio"] >= 0.60 else "medium",
                **metrics,
            })
    return junctions


def _contour_observations(level: dict, voxel: float) -> list[dict]:
    observations = []
    for contour in level.get("contours", []):
        points = np.asarray(contour.get("points", []), dtype=float)
        for first, second in zip(points, points[1:]):
            delta = second[[0, 2]] - first[[0, 2]]
            length = float(np.linalg.norm(delta))
            if length < voxel * 3.0:
                continue
            direction = delta / length
            if direction[0] < -1e-9 or (abs(direction[0]) <= 1e-9 and direction[1] < 0.0):
                direction = -direction
            normal = np.asarray([-direction[1], direction[0]])
            midpoint = (first + second) * 0.5
            interval = sorted((float(first[[0, 2]] @ direction), float(second[[0, 2]] @ direction)))
            observations.append({
                "y": float(level["y"]),
                "first": first,
                "second": second,
                "midpoint": midpoint,
                "direction": direction,
                "normal": normal,
                "offset": float(midpoint[[0, 2]] @ normal),
                "interval": interval,
                "length": length,
            })
    return observations


def _fit_contour_track(track: dict, step: float, envelope_height: float) -> dict:
    observations = track["observations"]
    directions = np.asarray([item["direction"] for item in observations])
    weights = np.asarray([item["length"] for item in observations])
    reference = directions[0]
    directions = np.asarray([
        direction if float(direction @ reference) >= 0.0 else -direction
        for direction in directions
    ])
    direction = np.average(directions, axis=0, weights=weights)
    direction /= max(float(np.linalg.norm(direction)), 1e-12)
    normal_xz = np.asarray([-direction[1], direction[0]])
    ys = np.asarray([item["y"] for item in observations])
    midpoints = np.asarray([item["midpoint"] for item in observations])
    offsets = midpoints[:, [0, 2]] @ normal_xz
    design = np.column_stack((ys, np.ones(len(ys))))
    slope, intercept = np.linalg.lstsq(design * weights[:, None], offsets * weights, rcond=None)[0]
    residuals = offsets - (slope * ys + intercept)
    median = float(np.median(residuals))
    mad = float(np.median(np.abs(residuals - median)))
    inliers = np.abs(residuals - median) <= max(3.0 * mad, step * 0.35)
    if int(inliers.sum()) >= 3 and not np.all(inliers):
        fit_weights = weights[inliers]
        fit_design = design[inliers]
        slope, intercept = np.linalg.lstsq(
            fit_design * fit_weights[:, None], offsets[inliers] * fit_weights, rcond=None
        )[0]
    normal = np.asarray([normal_xz[0], -slope, normal_xz[1]], dtype=float)
    scale = float(np.linalg.norm(normal))
    normal /= max(scale, 1e-12)
    d = -float(intercept) / max(scale, 1e-12)
    horizontal, _ = _plane_axes(normal)
    if float(horizontal[[0, 2]] @ direction) < 0.0:
        horizontal = -horizontal
    intervals = np.asarray([
        sorted((float(item["first"] @ horizontal), float(item["second"] @ horizontal)))
        for item in observations
    ])
    y_min = float(ys.min() - step * 0.5)
    y_max = float(ys.max() + step * 0.5)
    return {
        "id": track["id"],
        "normal": normal.tolist(),
        "d": d,
        "horizontal": horizontal.tolist(),
        "u_min": float(np.median(intervals[:, 0])),
        "u_max": float(np.median(intervals[:, 1])),
        "y_min": y_min,
        "y_max": y_max,
        "height_ratio": float((y_max - y_min) / max(envelope_height, step)),
        "support_sections": len({item["level"] for item in observations}),
        "median_length": float(np.median([item["length"] for item in observations])),
        "rms": float(np.sqrt(np.mean(residuals ** 2))),
    }


def build_contour_envelope(
    section_evidence: dict,
    voxel: float,
    candidates: list[dict] | None = None,
    families: list[dict] | None = None,
) -> dict:
    """Track outer-section segments through height and loft persistent wall faces."""
    levels = section_evidence.get("levels", [])
    if not levels:
        return {"tracks": [], "faces": [], "junctions": [], "anchor_family_ids": []}
    step = float(section_evidence.get("step") or voxel * 5.0)
    envelope_height = max(levels[-1]["y"] - levels[0]["y"] + step, step)
    tracks = []
    max_level_gap = 2
    for level_index, level in enumerate(levels):
        observations = _contour_observations(level, voxel)
        pairings = []
        for observation_id, observation in enumerate(observations):
            for track in tracks:
                if level_index - track["last_level"] > max_level_gap:
                    continue
                angle = math.degrees(math.acos(np.clip(abs(float(
                    observation["direction"] @ track["direction"]
                )), 0.0, 1.0)))
                if angle > 10.0:
                    continue
                normal = track["normal"]
                offset = float(observation["midpoint"][[0, 2]] @ normal)
                offset_gap = abs(offset - track["offset"])
                if offset_gap > voxel * 4.0:
                    continue
                projected = sorted((
                    float(observation["first"][[0, 2]] @ track["direction"]),
                    float(observation["second"][[0, 2]] @ track["direction"]),
                ))
                previous = track["last_interval"]
                interval_gap = max(0.0, previous[0] - projected[1], projected[0] - previous[1])
                if interval_gap > voxel * 8.0:
                    continue
                score = angle / 10.0 + offset_gap / (voxel * 4.0) + interval_gap / (voxel * 8.0)
                pairings.append((score, track["id"], observation_id, offset, projected))
        used_tracks = set()
        used_observations = set()
        for _, track_id, observation_id, offset, projected in sorted(pairings):
            if track_id in used_tracks or observation_id in used_observations:
                continue
            track = tracks[track_id]
            observation = observations[observation_id]
            observation["level"] = level_index
            track["observations"].append(observation)
            track["last_level"] = level_index
            direction = track["direction"] + observation["direction"]
            track["direction"] = direction / max(float(np.linalg.norm(direction)), 1e-12)
            track["normal"] = np.asarray([-track["direction"][1], track["direction"][0]])
            track["offset"] = float(np.median([
                item["midpoint"][[0, 2]] @ track["normal"]
                for item in track["observations"][-7:]
            ]))
            track["last_interval"] = projected
            used_tracks.add(track_id)
            used_observations.add(observation_id)
        for observation_id, observation in enumerate(observations):
            if observation_id in used_observations:
                continue
            observation["level"] = level_index
            tracks.append({
                "id": len(tracks),
                "observations": [observation],
                "last_level": level_index,
                "direction": observation["direction"].copy(),
                "normal": observation["normal"].copy(),
                "offset": observation["offset"],
                "last_interval": observation["interval"],
            })

    fitted = []
    for track in tracks:
        support = len({item["level"] for item in track["observations"]})
        if support < 5:
            continue
        item = _fit_contour_track(track, step, envelope_height)
        if item["height_ratio"] < 0.35 or item["median_length"] < voxel * 4.0:
            continue
        item["source_track_id"] = track["id"]
        item["id"] = len(fitted)
        fitted.append(item)

    junctions = []
    for position, first in enumerate(fitted):
        for second in fitted[position + 1:]:
            y_min = max(first["y_min"], second["y_min"])
            y_max = min(first["y_max"], second["y_max"])
            if y_max <= y_min:
                continue
            first_height = first["y_max"] - first["y_min"]
            second_height = second["y_max"] - second["y_min"]
            if (y_max - y_min) / max(min(first_height, second_height), step) < 0.35:
                continue
            angle = math.degrees(math.acos(np.clip(abs(float(
                np.asarray(first["normal"]) @ np.asarray(second["normal"])
            )), 0.0, 1.0)))
            if angle < 30.0:
                continue
            midpoint = _plane_intersection_at_y(first, second, (y_min + y_max) * 0.5)
            if midpoint is None:
                continue
            sides = {}
            gaps = []
            for item in (first, second):
                u = float(midpoint @ np.asarray(item["horizontal"]))
                distances = [abs(u - item["u_min"]), abs(u - item["u_max"])]
                sides[str(item["id"])] = "min" if distances[0] <= distances[1] else "max"
                gaps.append(min(distances))
            if max(gaps) > voxel * 6.0:
                continue
            junctions.append({
                "id": len(junctions),
                "tracks": [first["id"], second["id"]],
                "angle": angle,
                "y_range": [y_min, y_max],
                "endpoint_gap": max(gaps),
                "sides": sides,
            })

    family_by_id = {
        family["id"]: family for family in (families or [])
        if family.get("members")
    }
    family_bounds = {
        family_id: _family_bounds(family, candidates or [])
        for family_id, family in family_by_id.items()
    } if candidates else {}
    for item in fitted:
        item_normal = np.asarray(item["normal"])
        item_horizontal = np.asarray(item["horizontal"])
        for family_id, family in family_by_id.items():
            bounds = family_bounds[family_id]
            y_min = max(item["y_min"], bounds["y_min"])
            y_max = min(item["y_max"], bounds["y_max"])
            if y_max <= y_min:
                continue
            angle = math.degrees(math.acos(np.clip(abs(float(
                item_normal @ np.asarray(family["normal"])
            )), 0.0, 1.0)))
            if angle < 30.0:
                continue
            midpoint = _plane_intersection_at_y(item, family, (y_min + y_max) * 0.5)
            if midpoint is None:
                continue
            item_u = float(midpoint @ item_horizontal)
            family_u = float(midpoint @ bounds["horizontal"])
            item_distances = [abs(item_u - item["u_min"]), abs(item_u - item["u_max"])]
            family_distances = [abs(family_u - bounds["u_min"]), abs(family_u - bounds["u_max"])]
            if min(item_distances) > voxel * 8.0:
                continue
            junctions.append({
                "id": len(junctions),
                "tracks": [item["id"]],
                "family_id": family_id,
                "angle": angle,
                "y_range": [y_min, y_max],
                "endpoint_gap": min(item_distances),
                "sides": {
                    str(item["id"]): "min" if item_distances[0] <= item_distances[1] else "max",
                    f"family:{family_id}": "min" if family_distances[0] <= family_distances[1] else "max",
                },
            })

    faces = []
    for item in fitted:
        horizontal = np.asarray(item["horizontal"])
        corners = np.asarray([
            _point_on_plane_at_uy(item, horizontal, item["u_min"], item["y_min"]),
            _point_on_plane_at_uy(item, horizontal, item["u_max"], item["y_min"]),
            _point_on_plane_at_uy(item, horizontal, item["u_max"], item["y_max"]),
            _point_on_plane_at_uy(item, horizontal, item["u_min"], item["y_max"]),
        ])
        snapped = []
        for side_name, indices in (("min", (0, 3)), ("max", (1, 2))):
            options = [
                junction for junction in junctions
                if item["id"] in junction["tracks"]
                and junction["sides"][str(item["id"])] == side_name
            ]
            if not options:
                continue
            junction = min(options, key=lambda value: value["endpoint_gap"])
            if "family_id" in junction:
                other = family_by_id[junction["family_id"]]
            else:
                other_id = next(track_id for track_id in junction["tracks"] if track_id != item["id"])
                other = fitted[other_id]
            replacements = []
            for corner_id in indices:
                intersection = _plane_intersection_at_y(item, other, float(corners[corner_id, 1]))
                if intersection is None:
                    replacements = []
                    break
                displacement = float(np.linalg.norm(
                    intersection[[0, 2]] - corners[corner_id, [0, 2]]
                ))
                replacements.append((corner_id, intersection, displacement))
            if replacements and max(value[2] for value in replacements) <= voxel * 12.0:
                for corner_id, intersection, _ in replacements:
                    corners[corner_id, [0, 2]] = intersection[[0, 2]]
                snapped.append(junction["id"])
        faces.append({
            "id": item["id"],
            "track_id": item["id"],
            "role": "structural",
            "envelope_role": "contour",
            "normal": item["normal"],
            "d": item["d"],
            "corners": corners.tolist(),
            "confidence": "high",
            "support_sections": item["support_sections"],
            "height_ratio": item["height_ratio"],
            "snapped_junction_ids": snapped,
        })
    return {
        "tracks": fitted,
        "faces": faces,
        "junctions": junctions,
        "anchor_family_ids": sorted({
            junction["family_id"] for junction in junctions if "family_id" in junction
        }),
    }


def _confidence_label(score: float) -> str:
    if score >= 0.72:
        return "high"
    if score >= 0.48:
        return "medium"
    return "low"


def build_topology_proposals(
    candidates: list[dict],
    families: list[dict],
    points: np.ndarray,
    normals: np.ndarray,
    voxel: float,
    section_evidence: dict | None = None,
) -> list[dict]:
    """Propose local bridges between coplanar patches without changing them."""
    proposals = []
    up = np.asarray([0.0, 1.0, 0.0])
    for family in families:
        members = [candidates[index] for index in family["members"]]
        if len(members) < 2:
            continue
        normal = np.asarray(family["normal"], dtype=float)
        vertical = _unit((up - normal * float(up @ normal)).reshape(1, 3))[0]
        horizontal = _unit(np.cross(vertical, normal).reshape(1, 3))[0]
        projected_u = points @ horizontal
        projected_v = points @ vertical
        distances = np.abs(points @ normal + float(family["d"]))
        angles = np.degrees(np.arccos(np.clip(np.abs(normals @ normal), 0.0, 1.0)))

        def ranges(candidate: dict) -> tuple[tuple[float, float], tuple[float, float]]:
            diagnostic = candidate.get("diagnostic", {})
            corners = np.asarray(diagnostic.get("clean_corners", candidate["corners"]), dtype=float)
            u_values = corners @ horizontal
            v_values = corners @ vertical
            return (
                (float(u_values.min()), float(u_values.max())),
                (float(v_values.min()), float(v_values.max())),
            )

        for left_position, left in enumerate(members):
            left_u, left_v = ranges(left)
            for right in members[left_position + 1:]:
                right_u, right_v = ranges(right)
                u_overlap = max(0.0, min(left_u[1], right_u[1]) - max(left_u[0], right_u[0]))
                v_overlap = max(0.0, min(left_v[1], right_v[1]) - max(left_v[0], right_v[0]))
                u_ratio = u_overlap / max(min(left_u[1] - left_u[0], right_u[1] - right_u[0]), 1e-12)
                v_ratio = v_overlap / max(min(left_v[1] - left_v[0], right_v[1] - right_v[0]), 1e-12)

                if left_v[1] < right_v[0] or right_v[1] < left_v[0]:
                    axis = "vertical"
                    low = left if left_v[1] < right_v[0] else right
                    high = right if low is left else left
                    low_u, low_v = ranges(low)
                    high_u, high_v = ranges(high)
                    first_min, first_max = max(low_u[0], high_u[0]), min(low_u[1], high_u[1])
                    second_min, second_max = low_v[1], high_v[0]
                    overlap_ratio = u_ratio
                    family_extent = max(float(family["vertical_extent"]), voxel)
                    gap_limit = max(voxel * 12.0, family_extent * 0.12)
                elif left_u[1] < right_u[0] or right_u[1] < left_u[0]:
                    axis = "horizontal"
                    low = left if left_u[1] < right_u[0] else right
                    high = right if low is left else left
                    low_u, low_v = ranges(low)
                    high_u, high_v = ranges(high)
                    first_min, first_max = max(low_v[0], high_v[0]), min(low_v[1], high_v[1])
                    second_min, second_max = low_u[1], high_u[0]
                    overlap_ratio = v_ratio
                    family_extent = max(float(family["horizontal_extent"]), voxel)
                    gap_limit = max(voxel * 8.0, family_extent * 0.08)
                else:
                    continue

                gap = max(0.0, second_max - second_min)
                if first_max <= first_min or overlap_ratio < 0.60 or gap > gap_limit:
                    continue
                if axis == "vertical":
                    bridge_mask = (
                        (projected_u >= first_min) & (projected_u <= first_max)
                        & (projected_v >= second_min) & (projected_v <= second_max)
                    )
                    coordinates = (
                        (first_min, second_min), (first_max, second_min),
                        (first_max, second_max), (first_min, second_max),
                    )
                else:
                    bridge_mask = (
                        (projected_v >= first_min) & (projected_v <= first_max)
                        & (projected_u >= second_min) & (projected_u <= second_max)
                    )
                    coordinates = (
                        (second_min, first_min), (second_max, first_min),
                        (second_max, first_max), (second_min, first_max),
                    )
                compatible = bridge_mask & (distances <= voxel * 5.0) & (angles <= 18.0)
                bridge_area = max((first_max - first_min) * gap, voxel * voxel)
                possible_cells = bridge_area / (voxel * voxel)
                minimum_evidence = max(8, int(math.ceil(possible_cells * 0.01)))
                evidence = int(compatible.sum())
                if evidence < minimum_evidence:
                    continue

                normal_coordinate = -float(family["d"])
                bridge_corners = [
                    (
                        horizontal * u_value
                        + vertical * v_value
                        + normal * normal_coordinate
                    ).tolist()
                    for u_value, v_value in coordinates
                ]
                section_metrics = {
                    "section_count": 0,
                    "supported_sections": 0,
                    "continuity_ratio": 0.0,
                    "support_length": 0.0,
                }
                if axis == "vertical" and section_evidence:
                    bridge_y = [corner[1] for corner in bridge_corners]
                    section_metrics = section_continuity(
                        section_evidence,
                        family["id"],
                        (first_min, first_max),
                        (min(bridge_y), max(bridge_y)),
                        voxel,
                    )
                point_strength = min(1.0, evidence / max(minimum_evidence * 3.0, 1.0))
                section_strength = (
                    section_metrics["continuity_ratio"]
                    if section_metrics["section_count"]
                    else 0.0
                )
                confidence_score = (
                    0.30 * min(1.0, overlap_ratio)
                    + 0.25 * point_strength
                    + 0.45 * section_strength
                )
                confidence = _confidence_label(confidence_score)
                section_verified = (
                    axis == "vertical"
                    and section_metrics["supported_sections"] >= 2
                    and section_metrics["continuity_ratio"] >= 0.50
                )
                proposals.append({
                    "id": len(proposals),
                    "family_id": family["id"],
                    "members": [left["id"], right["id"]],
                    "axis": axis,
                    "gap": gap,
                    "gap_limit": gap_limit,
                    "overlap_ratio": overlap_ratio,
                    "bridge_points": evidence,
                    "bridge_corners": bridge_corners,
                    "section_evidence": section_metrics,
                    "confidence_score": confidence_score,
                    "confidence": confidence,
                    "status": "accepted" if confidence == "high" and section_verified else "proposed",
                })
    return proposals


def build_family_reassignment_proposals(
    candidates: list[dict],
    families: list[dict],
    voxel: float,
    section_evidence: dict | None = None,
) -> list[dict]:
    """Find locally compatible clean cores that global plane grouping separated."""
    proposals = []
    up = np.asarray([0.0, 1.0, 0.0])
    for candidate in candidates:
        diagnostic = candidate.get("diagnostic")
        source_family = candidate.get("family_id")
        if (
            candidate.get("kind") != "vertical"
            or candidate.get("confidence") == "low"
            or candidate.get("role") != "detail"
            or diagnostic is None
            or diagnostic["core_count"] < 40
        ):
            continue
        clean_normal = np.asarray(diagnostic["clean_normal"], dtype=float)
        clean_center = np.asarray(diagnostic["clean_center"], dtype=float)
        clean_corners = np.asarray(diagnostic["clean_corners"], dtype=float)
        options = []
        for family in families:
            if family["id"] == source_family or family.get("role") != "structural":
                continue
            family_normal = np.asarray(family["normal"], dtype=float)
            alignment = abs(float(clean_normal @ family_normal))
            angle = math.degrees(math.acos(max(-1.0, min(1.0, alignment))))
            if angle > 8.0:
                continue
            offset = abs(float(family_normal @ clean_center) + float(family["d"]))
            offset_limit = min(
                voxel * 8.0,
                max(voxel * 3.0, 2.0 * (diagnostic["clean_rms"] + family["rms"])),
            )
            if offset > offset_limit:
                continue

            vertical = _unit((up - family_normal * float(up @ family_normal)).reshape(1, 3))[0]
            horizontal = _unit(np.cross(vertical, family_normal).reshape(1, 3))[0]
            candidate_u = clean_corners @ horizontal
            candidate_v = clean_corners @ vertical
            best_overlap = 0.0
            best_member = None
            for member_id in family["members"]:
                member = candidates[member_id]
                member_corners = np.asarray(
                    member.get("diagnostic", {}).get("clean_corners", member["corners"]),
                    dtype=float,
                )
                member_u = member_corners @ horizontal
                member_v = member_corners @ vertical
                u_overlap = max(0.0, min(candidate_u.max(), member_u.max()) - max(candidate_u.min(), member_u.min()))
                v_overlap = max(0.0, min(candidate_v.max(), member_v.max()) - max(candidate_v.min(), member_v.min()))
                u_ratio = u_overlap / max(min(np.ptp(candidate_u), np.ptp(member_u)), 1e-12)
                v_ratio = v_overlap / max(min(np.ptp(candidate_v), np.ptp(member_v)), 1e-12)
                overlap = min(float(u_ratio), float(v_ratio))
                if overlap > best_overlap:
                    best_overlap = overlap
                    best_member = member_id
            if best_overlap < 0.20:
                continue
            y_values = clean_corners[:, 1]
            section_metrics = section_continuity(
                section_evidence or {},
                family["id"],
                (float(candidate_u.min()), float(candidate_u.max())),
                (float(y_values.min()), float(y_values.max())),
                voxel,
            )
            section_strength = section_metrics["continuity_ratio"] if section_metrics["section_count"] else 0.0
            confidence_score = (
                0.25 * (1.0 - min(1.0, angle / 8.0))
                + 0.25 * (1.0 - min(1.0, offset / offset_limit))
                + 0.20 * min(1.0, best_overlap)
                + 0.30 * section_strength
            )
            score = 1.0 - confidence_score
            options.append((
                score, family, angle, offset, offset_limit, best_overlap,
                best_member, section_metrics, confidence_score,
            ))

        if options:
            (
                _, family, angle, offset, offset_limit, overlap, member_id,
                section_metrics, confidence_score,
            ) = min(options, key=lambda item: item[0])
            confidence = _confidence_label(confidence_score)
            section_verified = (
                section_metrics["supported_sections"] >= 2
                and section_metrics["continuity_ratio"] >= 0.50
            )
            proposals.append({
                "id": len(proposals),
                "candidate_id": candidate["id"],
                "from_family_id": source_family,
                "to_family_id": family["id"],
                "reference_member_id": member_id,
                "angle": angle,
                "offset": offset,
                "offset_limit": offset_limit,
                "overlap_ratio": overlap,
                "section_evidence": section_metrics,
                "confidence_score": confidence_score,
                "confidence": confidence,
                "status": "accepted" if confidence == "high" and section_verified else "proposed",
            })
    return proposals


def _point_on_plane_at_uy(family: dict, horizontal: np.ndarray, u: float, y: float) -> np.ndarray:
    normal = np.asarray(family["normal"], dtype=float)
    horizontal_normal = np.asarray([normal[0], 0.0, normal[2]])
    denominator = float(horizontal_normal @ horizontal_normal)
    if denominator < 1e-10:
        raise ValueError("Il piano non e verticale")
    correction = horizontal_normal * (
        -(normal[1] * y + float(family["d"])) / denominator
    )
    return horizontal * u + np.asarray([0.0, y, 0.0]) + correction


def _snap_corners_to_junctions(
    corners: np.ndarray,
    family_id: int | None,
    family_by_id: dict[int, dict],
    envelope_junctions: list[dict],
) -> tuple[np.ndarray, list[int]]:
    family = family_by_id.get(family_id)
    if family is None:
        return corners, []
    corrected = corners.copy()
    snapped_junction_ids = []
    normal = np.asarray(family["normal"], dtype=float)
    for junction in envelope_junctions:
        if family_id not in junction["families"]:
            continue
        other_id = next(item for item in junction["families"] if item != family_id)
        other = family_by_id.get(other_id)
        if other is None:
            continue
        face_y_min = float(corrected[:, 1].min())
        face_y_max = float(corrected[:, 1].max())
        overlap_min = max(face_y_min, float(junction["y_range"][0]))
        overlap_max = min(face_y_max, float(junction["y_range"][1]))
        face_height = max(face_y_max - face_y_min, 1e-9)
        if overlap_max <= overlap_min or (overlap_max - overlap_min) / face_height < 0.40:
            continue
        horizontal, _ = _plane_axes(normal)
        projected = corrected @ horizontal
        side = junction["sides"][str(family_id)]
        boundary = float(projected.min() if side == "min" else projected.max())
        midpoint = _plane_intersection_at_y(family, other, (overlap_min + overlap_max) * 0.5)
        if midpoint is None:
            continue
        target = float(midpoint @ horizontal)
        if abs(target - boundary) > float(junction["snap_limit"]):
            continue
        order = np.argsort(projected)
        boundary_indices = order[:2] if side == "min" else order[-2:]
        for corner_id in boundary_indices:
            intersection = _plane_intersection_at_y(
                family, other, float(corrected[corner_id, 1])
            )
            if intersection is not None:
                corrected[corner_id, [0, 2]] = intersection[[0, 2]]
        snapped_junction_ids.append(junction["id"])
    return corrected, snapped_junction_ids


def build_family_envelope_faces(
    candidates: list[dict],
    families: list[dict],
    envelope_junctions: list[dict],
    voxel: float,
) -> list[dict]:
    """Merge structural patches into persistent planar envelope components."""
    structural = [family for family in families if family.get("role") == "structural"]
    if not structural:
        return []
    family_by_id = {family["id"]: family for family in families}
    all_bounds = {family["id"]: _family_bounds(family, candidates) for family in structural}
    global_y_min = min(bounds["y_min"] for bounds in all_bounds.values())
    global_y_max = max(bounds["y_max"] for bounds in all_bounds.values())
    global_height = max(global_y_max - global_y_min, voxel)
    faces = []
    for family in structural:
        normal = np.asarray(family["normal"], dtype=float)
        horizontal, _ = _plane_axes(normal)
        patches = []
        for member_id in family["members"]:
            candidate = candidates[member_id]
            corners = np.asarray(candidate.get("diagnostic", {}).get(
                "clean_corners", candidate["corners"]
            ), dtype=float)
            projected = corners @ horizontal
            patches.append({
                "u_min": float(projected.min()),
                "u_max": float(projected.max()),
                "y_min": float(corners[:, 1].min()),
                "y_max": float(corners[:, 1].max()),
                "members": [member_id],
            })
        components = []
        for patch in sorted(patches, key=lambda item: item["u_min"]):
            if components and patch["u_min"] <= components[-1]["u_max"] + voxel * 6.0:
                component = components[-1]
                component["u_max"] = max(component["u_max"], patch["u_max"])
                component["y_min"] = min(component["y_min"], patch["y_min"])
                component["y_max"] = max(component["y_max"], patch["y_max"])
                component["members"].extend(patch["members"])
            else:
                components.append(patch.copy())
        family_height_ratio = (
            all_bounds[family["id"]]["y_max"] - all_bounds[family["id"]]["y_min"]
        ) / global_height
        for component in components:
            y_min = global_y_min if family_height_ratio >= 0.72 else component["y_min"]
            y_max = global_y_max if family_height_ratio >= 0.72 else component["y_max"]
            corners = np.asarray([
                _point_on_plane_at_uy(family, horizontal, component["u_min"], y_min),
                _point_on_plane_at_uy(family, horizontal, component["u_max"], y_min),
                _point_on_plane_at_uy(family, horizontal, component["u_max"], y_max),
                _point_on_plane_at_uy(family, horizontal, component["u_min"], y_max),
            ])
            corners, snapped = _snap_corners_to_junctions(
                corners, family["id"], family_by_id, envelope_junctions
            )
            if family_height_ratio < 0.35 and not snapped:
                continue
            faces.append({
                "id": len(faces),
                "family_id": family["id"],
                "source_candidate_ids": component["members"],
                "role": "structural",
                "envelope_role": family.get("envelope_role", "main"),
                "normal": family["normal"],
                "d": family["d"],
                "corners": corners.tolist(),
                "height_aligned": family_height_ratio >= 0.72,
                "height_ratio": family_height_ratio,
                "snapped_junction_ids": snapped,
                "confidence": "high",
            })
    return faces


def build_candidates_v2(
    candidates: list[dict],
    families: list[dict],
    topology_proposals: list[dict],
    reassignment_proposals: list[dict],
    section_evidence: dict,
    envelope_junctions: list[dict] | None = None,
) -> dict:
    """Build a non-destructive corrected layer from high-confidence decisions."""
    family_by_id = {family["id"]: family for family in families}
    envelope_junctions = envelope_junctions or []
    accepted_reassignments = {
        proposal["candidate_id"]: proposal
        for proposal in reassignment_proposals
        if proposal["status"] == "accepted"
    }
    faces = []
    uncertainty = []
    attachments = []
    for candidate in candidates:
        diagnostic = candidate.get("diagnostic")
        if candidate.get("kind") != "vertical" or diagnostic is None:
            continue
        reassignment = accepted_reassignments.get(candidate["id"])
        family_id = reassignment["to_family_id"] if reassignment else candidate.get("family_id")
        family = family_by_id.get(family_id)
        normal = np.asarray(
            family["normal"] if family else diagnostic["clean_normal"],
            dtype=float,
        )
        d = float(family["d"]) if family else -float(normal @ np.asarray(diagnostic["clean_center"]))
        source_corners = np.asarray(candidate["corners"], dtype=float)
        corrected_corners = source_corners - (source_corners @ normal + d)[:, None] * normal
        corrected_corners, snapped_junction_ids = _snap_corners_to_junctions(
            corrected_corners, family_id, family_by_id, envelope_junctions
        )
        faces.append({
            "id": len(faces),
            "source_candidate_id": candidate["id"],
            "family_id": family_id,
            "role": family.get("role", candidate.get("role", "detail")) if family else candidate.get("role", "detail"),
            "envelope_role": family.get("envelope_role", candidate.get("envelope_role", "detail")) if family else candidate.get("envelope_role", "detail"),
            "normal": normal.tolist(),
            "d": d,
            "corners": corrected_corners.tolist(),
            "reassigned": reassignment is not None,
            "snapped_junction_ids": snapped_junction_ids,
            "confidence": candidate.get("confidence", "low"),
        })
        if diagnostic.get("attachment_points"):
            attachments.append({
                "source_candidate_id": candidate["id"],
                "point_indices": diagnostic["attachment_points"],
            })

    promoted_family_ids = {
        family["id"] for family in families
        if family.get("promotion", {}).get("reason") == "persistent_contour_junction"
    }
    for family_id in promoted_family_ids:
        family = family_by_id[family_id]
        family_faces = sorted(
            (face for face in faces if face["family_id"] == family_id and not face.get("family_fill")),
            key=lambda face: min(corner[1] for corner in face["corners"]),
        )
        if len(family_faces) < 2:
            continue
        bounds = _family_bounds(family, candidates)
        horizontal = bounds["horizontal"]
        for lower, upper in zip(family_faces, family_faces[1:]):
            y_min = max(corner[1] for corner in lower["corners"])
            y_max = min(corner[1] for corner in upper["corners"])
            if y_max <= y_min:
                continue
            continuity = section_continuity(
                section_evidence,
                family_id,
                (bounds["u_min"], bounds["u_max"]),
                (y_min, y_max),
                float(section_evidence.get("step", 0.0)) / 5.0,
            )
            if continuity["supported_sections"] < 2 or continuity["continuity_ratio"] < 0.75:
                continue
            fill_corners = np.asarray([
                _point_on_plane_at_uy(family, horizontal, bounds["u_min"], y_min),
                _point_on_plane_at_uy(family, horizontal, bounds["u_max"], y_min),
                _point_on_plane_at_uy(family, horizontal, bounds["u_max"], y_max),
                _point_on_plane_at_uy(family, horizontal, bounds["u_min"], y_max),
            ])
            fill_corners, snapped_junction_ids = _snap_corners_to_junctions(
                fill_corners, family_id, family_by_id, envelope_junctions
            )
            faces.append({
                "id": len(faces),
                "source_candidate_id": lower["source_candidate_id"],
                "source_candidate_ids": [
                    lower["source_candidate_id"], upper["source_candidate_id"]
                ],
                "family_id": family_id,
                "role": "structural",
                "envelope_role": family.get("envelope_role", "return"),
                "normal": family["normal"],
                "d": family["d"],
                "corners": fill_corners.tolist(),
                "reassigned": False,
                "family_fill": True,
                "section_evidence": continuity,
                "snapped_junction_ids": snapped_junction_ids,
                "confidence": "high",
            })

    accepted_bridges = [
        proposal for proposal in topology_proposals
        if proposal["status"] == "accepted"
    ]
    for proposal in topology_proposals + reassignment_proposals:
        if proposal["status"] != "accepted":
            uncertainty.append({
                "type": "bridge" if "members" in proposal else "reassignment",
                "proposal_id": proposal["id"],
                "confidence": proposal.get("confidence", "low"),
                "confidence_score": proposal.get("confidence_score", 0.0),
            })
    return {
        "schema": "acrobatica.planar-topology.v2",
        "policy": {
            "normalization": "mesh median edge and adaptive section spacing",
            "automatic_changes": "high confidence with multi-section support only",
            "uncertain_changes": "retained as proposals without modifying geometry",
        },
        "section_summary": {
            "step": section_evidence.get("step", 0.0),
            "levels": len(section_evidence.get("levels", [])),
        },
        "faces": faces,
        "junctions": envelope_junctions,
        "bridges": accepted_bridges,
        "attachments": attachments,
        "uncertainty": uncertainty,
    }


def write_colored_points(path: Path, points: np.ndarray, candidates: list[dict], assignment: np.ndarray) -> None:
    colors = np.full((len(points), 3), 85, dtype=np.uint8)
    for candidate in candidates:
        color_index = candidate.get("family_id")
        if color_index is None:
            color_index = candidate["id"]
        colors[assignment == candidate["id"]] = color_for(color_index, candidate["confidence"])
    with path.open("wb") as output:
        header = (
            "ply\nformat binary_little_endian 1.0\n"
            f"element vertex {len(points)}\n"
            "property float x\nproperty float y\nproperty float z\n"
            "property uchar red\nproperty uchar green\nproperty uchar blue\n"
            "end_header\n"
        )
        output.write(header.encode("ascii"))
        record = struct.Struct("<fffBBB")
        for point, color in zip(points, colors):
            output.write(record.pack(float(point[0]), float(point[1]), float(point[2]), *map(int, color)))


def write_viewer(path: Path, model_name: str) -> None:
    template = r'''<!doctype html>
<html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Topologia piani v2</title><style>
:root{color-scheme:dark;font-family:Inter,system-ui,sans-serif;letter-spacing:0}*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#17191a}canvas{display:block}.panel{position:fixed;z-index:3;left:16px;top:16px;width:min(400px,calc(100vw - 32px));max-height:calc(100vh - 32px);overflow:auto;padding:14px;background:rgba(28,31,32,.96);border:1px solid #42484a;border-radius:6px;color:#f3f4f4;box-shadow:0 12px 30px #0008}.panel h1{margin:0;font-size:16px}.sub{margin:4px 0 12px;color:#aeb6b9;font-size:11px;line-height:1.4}.metrics{display:grid;grid-template-columns:1fr auto;gap:7px;font-size:11px;padding:7px 0;border-top:1px solid #3a3f41}.modes{display:grid;grid-template-columns:.8fr .8fr 1.35fr 1fr;gap:2px;margin:10px 0;background:#202324;padding:2px;border-radius:5px}.modes button{font-size:10px;padding:0 5px}.modes button.active{background:#00aeef;color:#071115}.controls{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:10px}button,select{min-height:34px;border:0;border-radius:4px;background:#393e40;color:#f3f4f4;padding:0 9px}select{width:100%}button{cursor:pointer}button:hover{background:#4a5053}.checks{display:grid;grid-template-columns:1fr 1fr;gap:9px;margin-top:11px;font-size:11px;color:#d0d5d7}.checks label{display:flex;align-items:center;gap:7px}.checks input{width:17px;height:17px;accent-color:#00aeef}.legend{display:flex;flex-wrap:wrap;gap:10px;margin-top:11px;font-size:10px;color:#c3c9cb}.legend span{display:flex;align-items:center;gap:5px}.swatch{width:10px;height:10px;border-radius:2px}.original{background:#00aeef}.corrected{background:#f4c20d}.wall{background:#00aeef}.return{background:#36d399}.attachment{background:#ff8a00}.opening{background:#e5398f}.uncertain{background:#697074}.bridge{border:2px dashed #a6ff00;background:transparent}.detail{margin-top:11px;padding:9px;background:#232627;border-left:3px solid #00aeef;color:#c3c9cb;font-size:10px;line-height:1.5;min-height:68px}#status{position:fixed;z-index:3;bottom:18px;left:50%;transform:translateX(-50%);padding:9px 13px;background:#202324;border:1px solid #42484a;border-radius:4px;font-size:11px;color:#d6dadd}
</style><script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.166.1/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.166.1/examples/jsm/"}}</script></head><body>
<aside class="panel"><h1>Topologia piani v2</h1><p class="sub">Le correzioni automatiche richiedono supporto geometrico su più sezioni. Le decisioni incerte restano proposte.</p><div id="metrics"></div><div class="modes"><button data-mode="original">Originali</button><button data-mode="corrected">Corretti</button><button data-mode="contour" class="active">Involucro</button><button data-mode="semantic">Semantica AI</button></div><select id="candidate"><option value="-1">Tutti i candidati</option></select><div class="controls"><button id="front">Frontale</button><button id="fit">Adatta</button></div><div class="checks"><label><input id="mesh" type="checkbox" checked> Mesh raw</label><label><input id="points" type="checkbox"> Supporto</label><label><input id="planes" type="checkbox" checked> Piani</label><label><input id="diagnostic" type="checkbox"> Nucleo</label><label><input id="topology" type="checkbox" checked> Topologia</label><label><input id="structural" type="checkbox" checked> Solo strutturali</label><label><input id="low" type="checkbox"> Bassa confidenza</label><label><input id="horizontal" type="checkbox"> Orizzontali</label></div><div class="legend"><span><i class="swatch wall"></i>Parete</span><span><i class="swatch return"></i>Spalletta</span><span><i class="swatch attachment"></i>Sporgenza</span><span><i class="swatch opening"></i>Apertura</span><span><i class="swatch uncertain"></i>Incerto</span><span><i class="swatch bridge"></i>Proposta</span></div><div id="detail" class="detail">Seleziona un piano per leggere la classificazione.</div></aside><div id="status">Caricamento topologia...</div>
<script type="module">
import * as THREE from 'three';
import{OrbitControls}from'three/addons/controls/OrbitControls.js';
import{OBJLoader}from'three/addons/loaders/OBJLoader.js';
import{PLYLoader}from'three/addons/loaders/PLYLoader.js';

const [data,v2]=await Promise.all([fetch('./candidates.json').then(r=>r.json()),fetch('./candidates.v2.json').then(r=>r.json())]);
const scene=new THREE.Scene();scene.background=new THREE.Color(0x17191a);
const camera=new THREE.PerspectiveCamera(38,innerWidth/innerHeight,.01,1000);
const renderer=new THREE.WebGLRenderer({antialias:true});renderer.setPixelRatio(Math.min(devicePixelRatio,2));renderer.setSize(innerWidth,innerHeight);document.body.prepend(renderer.domElement);
const controls=new OrbitControls(camera,renderer.domElement);controls.enableDamping=true;controls.screenSpacePanning=true;
scene.add(new THREE.HemisphereLight(0xeef6ff,0x34383a,2));const key=new THREE.DirectionalLight(0xffead2,3);key.position.set(-7,10,9);scene.add(key);
const root=await new OBJLoader().loadAsync('./MODEL_NAME'),rootMaterials=[];root.traverse(o=>{if(o.isMesh){o.material=new THREE.MeshStandardMaterial({color:0x9ca5a8,roughness:.9,metalness:0,transparent:true,opacity:.24,side:THREE.DoubleSide,depthWrite:false});rootMaterials.push(o.material);}});scene.add(root);
const supportGeometry=await new PLYLoader().loadAsync('./support_points.ply');const supportPoints=new THREE.Points(supportGeometry,new THREE.PointsMaterial({size:data.voxel_size*.7,vertexColors:true,sizeAttenuation:true}));scene.add(supportPoints);
const sampleGeometry=await new PLYLoader().loadAsync('./samples.ply');const samplePositions=sampleGeometry.getAttribute('position');
const originalGroup=new THREE.Group(),correctedGroup=new THREE.Group(),contourGroup=new THREE.Group(),bridgeGroup=new THREE.Group(),diagnosticGroup=new THREE.Group(),proposalGroup=new THREE.Group();scene.add(originalGroup,correctedGroup,contourGroup,bridgeGroup,diagnosticGroup,proposalGroup);
const palette=[0x00aeef,0xff7a00,0x00c48c,0xe5398f,0xf4c20d,0x7e57c2,0x27ae60,0xeb5757],originalMeshes=[],correctedMeshes=[];
function faceMesh(record,color){const c=record.corners.map(v=>new THREE.Vector3(...v));const g=new THREE.BufferGeometry().setFromPoints([c[0],c[1],c[2],c[0],c[2],c[3]]);g.computeVertexNormals();const mesh=new THREE.Mesh(g,new THREE.MeshBasicMaterial({color,side:THREE.DoubleSide,polygonOffset:true,polygonOffsetFactor:-1}));mesh.userData=record;mesh.add(new THREE.LineSegments(new THREE.EdgesGeometry(g),new THREE.LineBasicMaterial({color:0xffffff})));return mesh;}
for(const p of data.candidates){const low=p.confidence==='low',color=low?0x777c7e:palette[(p.family_id??p.id)%palette.length],mesh=faceMesh(p,color);originalGroup.add(mesh);originalMeshes.push(mesh);}
for(const p of v2.faces){const color=p.reassigned?0xa6ff00:0xf4c20d,mesh=faceMesh(p,color);correctedGroup.add(mesh);correctedMeshes.push(mesh);}
const contourAnchorFamilies=new Set(v2.contour_anchor_family_ids||[]);
for(const p of v2.envelope_faces||v2.faces.filter(item=>item.role==='structural'||contourAnchorFamilies.has(item.family_id)))contourGroup.add(faceMesh(p,0xf4c20d));
for(const p of v2.bridges){const mesh=faceMesh({...p,corners:p.bridge_corners},0xa6ff00);mesh.material.transparent=true;mesh.material.opacity=.8;bridgeGroup.add(mesh);}
const clearGroup=group=>{for(const child of [...group.children]){group.remove(child);child.geometry?.dispose();child.material?.dispose();}};
function diagnosticPoints(indices,color){const values=new Float32Array(indices.length*3);for(let i=0;i<indices.length;i++){const source=indices[i];values[i*3]=samplePositions.getX(source);values[i*3+1]=samplePositions.getY(source);values[i*3+2]=samplePositions.getZ(source);}const geometry=new THREE.BufferGeometry();geometry.setAttribute('position',new THREE.BufferAttribute(values,3));return new THREE.Points(geometry,new THREE.PointsMaterial({color,size:data.voxel_size*1.2,sizeAttenuation:true,depthTest:false}));}
function lineLoop(corners,color,dashed=false){const values=corners.map(v=>new THREE.Vector3(...v));values.push(values[0].clone());const material=dashed?new THREE.LineDashedMaterial({color,dashSize:data.voxel_size*4,gapSize:data.voxel_size*2,depthTest:false}):new THREE.LineBasicMaterial({color,depthTest:false});const line=new THREE.Line(new THREE.BufferGeometry().setFromPoints(values),material);if(dashed)line.computeLineDistances();return line;}
let mode='contour',semanticData=null,semanticPoints=null,semanticLoading=null;
async function ensureSemantic(){if(semanticPoints)return semanticPoints;if(semanticLoading)return semanticLoading;semanticLoading=(async()=>{semanticData=await fetch('./semantic/semantic_evidence.v1.json').then(r=>{if(!r.ok)throw new Error('Dati semantici non disponibili');return r.json();});const geometry=await new PLYLoader().loadAsync('./semantic/semantic_points.ply');semanticPoints=new THREE.Points(geometry,new THREE.PointsMaterial({size:data.voxel_size*.72,vertexColors:true,sizeAttenuation:true,depthTest:true}));scene.add(semanticPoints);return semanticPoints;})();return semanticLoading;}
function updateDiagnostic(candidate){clearGroup(diagnosticGroup);clearGroup(proposalGroup);if(!candidate)return;const d=candidate.diagnostic;if(document.getElementById('diagnostic').checked&&d){diagnosticGroup.add(diagnosticPoints(d.core_points,0x00d084));diagnosticGroup.add(lineLoop(d.clean_corners,0x00ff9d));}if(mode==='attachments'&&d)diagnosticGroup.add(diagnosticPoints(d.attachment_points,0xff8a00));if(document.getElementById('topology').checked){for(const proposal of data.topology_proposals||[]){if(proposal.members.includes(candidate.id)&&proposal.status!=='accepted')proposalGroup.add(lineLoop(proposal.bridge_corners,0xa6ff00,true));}}}
const acceptedBridges=v2.bridges.length,acceptedReassignments=v2.faces.filter(p=>p.reassigned).length,structuralCount=data.families.filter(p=>p.role==='structural').length;
document.getElementById('metrics').innerHTML=`<div class="metrics"><span>Sezioni orizzontali</span><strong>${v2.section_summary.levels}</strong></div><div class="metrics"><span>Famiglie strutturali</span><strong>${structuralCount}</strong></div><div class="metrics"><span>Facce involucro</span><strong>${(v2.envelope_faces||[]).length}</strong></div><div class="metrics"><span>Raccordi accettati</span><strong>${acceptedBridges}</strong></div><div class="metrics"><span>Decisioni incerte</span><strong>${v2.uncertainty.length}</strong></div>`;
const select=document.getElementById('candidate'),structuralToggle=document.getElementById('structural'),lowToggle=document.getElementById('low'),horizontalToggle=document.getElementById('horizontal'),detailBox=document.getElementById('detail');
for(const p of data.candidates){const o=document.createElement('option');o.value=p.id;o.textContent=`${p.name} | F${p.family_id===null?'-':p.family_id+1} | ${p.role}`;select.append(o);}
const requested=Number(new URLSearchParams(location.search).get('plane'));if(Number.isFinite(requested)&&requested>0&&requested<=data.candidates.length)select.value=String(requested-1);
function recordVisible(p,chosen){const ids=p.source_candidate_ids??[p.source_candidate_id??p.id];return chosen>=0?ids.includes(chosen):(!structuralToggle.checked||p.role==='structural')&&(p.confidence!=='low'||lowToggle.checked)&&(p.kind!=='horizontal'||horizontalToggle.checked);}
function visible(){const chosen=+select.value,candidate=chosen>=0?data.candidates[chosen]:null;for(const mesh of originalMeshes)mesh.visible=recordVisible(mesh.userData,chosen);for(const mesh of correctedMeshes)mesh.visible=recordVisible(mesh.userData,chosen);for(const mesh of bridgeGroup.children)mesh.visible=chosen<0||mesh.userData.members.includes(chosen);originalGroup.visible=document.getElementById('planes').checked&&mode==='original';correctedGroup.visible=document.getElementById('planes').checked&&mode==='corrected';contourGroup.visible=document.getElementById('planes').checked&&mode==='contour';bridgeGroup.visible=document.getElementById('planes').checked&&mode==='corrected'&&document.getElementById('topology').checked;supportPoints.visible=mode!=='semantic'&&document.getElementById('points').checked&&!candidate;if(semanticPoints)semanticPoints.visible=mode==='semantic';for(const material of rootMaterials)material.opacity=mode==='semantic'?.12:.24;updateDiagnostic(mode==='semantic'||mode==='contour'?null:candidate);if(mode==='contour'){detailBox.textContent=`Involucro composto da ${(v2.envelope_faces||[]).length} superfici continue; ${(v2.envelope_faces||[]).filter(item=>item.height_aligned).length} allineate in altezza e ${(v2.envelope_faces||[]).reduce((sum,item)=>sum+item.snapped_junction_ids.length,0)} agganci agli spigoli condivisi.`;}else if(mode==='semantic'&&semanticData){const counts=Object.fromEntries(semanticData.classes.map(item=>[item.name,item.faces]));detailBox.textContent=`Consenso multivista ${Math.round(semanticData.selection.achieved_coverage*100)}%. Parete ${(counts.wall||0).toLocaleString('it')}; spallette ${(counts.return||0).toLocaleString('it')}; sporgenze ${(counts.attachment||0).toLocaleString('it')}; aperture ${(counts.opening||0).toLocaleString('it')}; incerte ${(counts.uncertain||0).toLocaleString('it')}. Nessuna geometria modificata.`;}else if(candidate){const d=candidate.diagnostic,proposals=(data.topology_proposals||[]).filter(item=>item.members.includes(candidate.id)),accepted=proposals.filter(item=>item.status==='accepted').length,reassignment=(data.family_reassignment_proposals||[]).find(item=>item.candidate_id===candidate.id);const reassignmentText=reassignment?` Riassegnazione ${reassignment.status}: F${reassignment.from_family_id+1} -> F${reassignment.to_family_id+1}, confidenza ${reassignment.confidence}.`:'';detailBox.textContent=`${candidate.name} | famiglia ${candidate.family_id===null?'non assegnata':candidate.family_id+1} | ${candidate.role}. Supporto ${candidate.support_points.toLocaleString('it')}; nucleo ${d.core_count.toLocaleString('it')}; sporgenze/incerti ${d.attachment_count.toLocaleString('it')}; RMS pulito ${d.clean_rms.toFixed(4)}; raccordi ${accepted}/${proposals.length} accettati.${reassignmentText}`;}else if(mode!=='semantic'){clearGroup(diagnosticGroup);clearGroup(proposalGroup);detailBox.textContent='La vista Corretti applica solo decisioni validate su più sezioni; le altre restano nel file delle incertezze.';}}
for(const id of ['candidate','structural','low','horizontal','diagnostic','topology','planes','points'])document.getElementById(id).onchange=visible;
for(const button of document.querySelectorAll('[data-mode]'))button.onclick=async()=>{mode=button.dataset.mode;for(const item of document.querySelectorAll('[data-mode]'))item.classList.toggle('active',item===button);if(mode==='semantic'){select.value='-1';detailBox.textContent='Carico le etichette semantiche...';try{await ensureSemantic();}catch(error){detailBox.textContent=error.message;mode='original';}}visible();};
document.getElementById('mesh').onchange=e=>root.visible=e.target.checked;
const box=new THREE.Box3().setFromObject(root),center=box.getCenter(new THREE.Vector3()),size=box.getSize(new THREE.Vector3()),mainPlane=data.candidates.find(p=>p.role==='structural')||data.candidates[0];
function fit(){controls.target.copy(center);camera.position.set(center.x+size.x*.15,center.y+size.y*.05,center.z+Math.max(size.x,size.y)*1.15);camera.up.set(0,1,0);camera.near=Math.max(size.length()/5000,.001);camera.far=size.length()*30;camera.updateProjectionMatrix();controls.update();}
function frontView(){const chosen=+select.value,p=chosen>=0?data.candidates[chosen]:mainPlane,normal=new THREE.Vector3(...p.normal).normalize(),target=chosen>=0?new THREE.Vector3(...p.center):center;controls.target.copy(target);camera.position.copy(target).addScaledVector(normal,size.length()*1.15);camera.up.set(0,1,0);camera.lookAt(target);controls.update();}
document.getElementById('front').onclick=frontView;document.getElementById('fit').onclick=fit;document.getElementById('status').remove();visible();frontView();addEventListener('resize',()=>{camera.aspect=innerWidth/innerHeight;camera.updateProjectionMatrix();renderer.setSize(innerWidth,innerHeight)});renderer.setAnimationLoop(()=>{controls.update();renderer.render(scene,camera)});
</script></body></html>'''
    path.write_text(template.replace("MODEL_NAME", model_name))


def run(args: argparse.Namespace) -> Path:
    mesh = args.mesh.resolve()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if not args.binary.exists():
        raise RuntimeError(f"Eseguibile CGAL assente: {args.binary}")

    print(f"Lettura {mesh}")
    raw_points, raw_normals, median_edge, mesh_vertices, mesh_faces = load_obj_samples(mesh)
    voxel = median_edge * args.voxel_factor
    points, normals = voxelize(raw_points, raw_normals, voxel)
    print(f"Vertici {len(raw_points):,} -> campioni {len(points):,}; edge mediano={median_edge:.6g}; voxel={voxel:.6g}")
    point_set_path = output / "samples.ply"
    write_point_set(point_set_path, points, normals)

    all_regions = []
    all_labels = []
    scale_summary = []
    for scale in SCALES:
        distance = median_edge * scale.distance_factor
        region_path = output / f"regions_{scale.name}.csv"
        label_path = output / f"labels_{scale.name}.csv"
        command = [
            str(args.binary), str(point_set_path), str(region_path), str(label_path),
            str(scale.k), repr(distance), repr(scale.angle), str(scale.min_region),
        ]
        print(" ".join(command))
        subprocess.run(command, check=True)
        regions = read_regions(region_path, scale, distance)
        labels = read_labels(label_path)
        all_regions.append(regions)
        all_labels.append(labels)
        scale_summary.append({
            "name": scale.name,
            "k": scale.k,
            "max_distance": distance,
            "max_angle": scale.angle,
            "min_region": scale.min_region,
            "regions": len(regions),
            "assigned_points": int((labels >= 0).sum()),
        })

    groups = associate_regions(all_regions, all_labels)
    candidates, assignment = build_candidates(
        groups, all_regions, all_labels, points, normals, voxel
    )
    families = assign_plane_families(candidates, points, voxel)
    print("Intersezioni orizzontali adattive")
    section_evidence = build_horizontal_section_evidence(
        mesh_vertices, mesh_faces, families, voxel
    )
    contour_envelope = build_contour_envelope(
        section_evidence, voxel, candidates, families
    )
    envelope_junctions = classify_envelope_roles(
        candidates, families, section_evidence, voxel
    )
    topology_proposals = build_topology_proposals(
        candidates, families, points, normals, voxel, section_evidence
    )
    family_reassignment_proposals = build_family_reassignment_proposals(
        candidates, families, voxel, section_evidence
    )
    document = {
        "schema": "acrobatica.multiscale-plane-candidates.v1",
        "source_mesh": str(mesh),
        "raw_points": len(raw_points),
        "sample_points": len(points),
        "median_edge": median_edge,
        "voxel_size": voxel,
        "up": [0.0, 1.0, 0.0],
        "scales": scale_summary,
        "families": families,
        "candidates": candidates,
        "section_evidence": section_evidence,
        "envelope_junctions": envelope_junctions,
        "contour_envelope": contour_envelope,
        "topology_proposals": topology_proposals,
        "family_reassignment_proposals": family_reassignment_proposals,
    }
    (output / "candidates.json").write_text(json.dumps(document, indent=2))
    candidates_v2 = build_candidates_v2(
        candidates,
        families,
        topology_proposals,
        family_reassignment_proposals,
        section_evidence,
        envelope_junctions,
    )
    candidates_v2["contour_tracks"] = contour_envelope["tracks"]
    candidates_v2["contour_faces"] = contour_envelope["faces"]
    candidates_v2["contour_junctions"] = contour_envelope["junctions"]
    candidates_v2["contour_anchor_family_ids"] = contour_envelope["anchor_family_ids"]
    candidates_v2["envelope_faces"] = build_family_envelope_faces(
        candidates, families, envelope_junctions, voxel
    )
    (output / "candidates.v2.json").write_text(json.dumps(candidates_v2, indent=2))
    write_colored_points(output / "support_points.ply", points, candidates, assignment)
    model_link = output / "model.obj"
    if model_link.exists() or model_link.is_symlink():
        model_link.unlink()
    try:
        model_link.symlink_to(mesh)
    except OSError:
        shutil.copy2(mesh, model_link)
    write_viewer(output / "viewer.html", model_link.name)
    print(f"Candidati: {len(candidates)}; viewer: {output / 'viewer.html'}")
    return output / "viewer.html"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mesh", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--voxel-factor", type=float, default=1.2)
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
