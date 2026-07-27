#!/usr/bin/env python3
"""Build a feature-preserving proxy from a dense Object Capture OBJ mesh.

The filter moves vertices only along their current normal. Open boundaries stay
fixed and neighbours across sharp normal discontinuities do not influence each
other. This removes high-frequency capture noise without shrinking the facade
in its tangent plane or rounding major architectural edges.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np


def load_obj(path: str | Path) -> tuple[np.ndarray, np.ndarray]:
    vertices: list[list[float]] = []
    faces: list[list[int]] = []
    with open(path, encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            if line.startswith("v "):
                vertices.append([float(value) for value in line.split()[1:4]])
            elif line.startswith("f "):
                polygon = [int(token.split("/")[0]) - 1 for token in line.split()[1:]]
                for index in range(1, len(polygon) - 1):
                    faces.append([polygon[0], polygon[index], polygon[index + 1]])
    return np.asarray(vertices, dtype=np.float64), np.asarray(faces, dtype=np.int32)


def write_obj(path: str | Path, vertices: np.ndarray, faces: np.ndarray) -> None:
    with open(path, "w", encoding="ascii") as handle:
        handle.write("# Feature-preserving Object Capture proxy\n")
        handle.write("o oc_proxy\n")
        for x, y, z in vertices:
            handle.write(f"v {x:.9g} {y:.9g} {z:.9g}\n")
        for a, b, c in faces:
            handle.write(f"f {a + 1} {b + 1} {c + 1}\n")


def vertex_normals(vertices: np.ndarray, faces: np.ndarray) -> np.ndarray:
    a, b, c = vertices[faces[:, 0]], vertices[faces[:, 1]], vertices[faces[:, 2]]
    face_normals = np.cross(b - a, c - a)
    normals = np.zeros_like(vertices)
    for corner in range(3):
        np.add.at(normals, faces[:, corner], face_normals)
    lengths = np.linalg.norm(normals, axis=1)
    valid = lengths > 1e-12
    normals[valid] /= lengths[valid, None]
    return normals


def mesh_edges(faces: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    all_edges = np.sort(
        np.concatenate(
            [faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]],
            axis=0,
        ),
        axis=1,
    )
    return np.unique(all_edges, axis=0, return_counts=True)


def smooth_proxy(
    vertices: np.ndarray,
    faces: np.ndarray,
    *,
    iterations: int,
    strength: float,
    feature_angle_deg: float,
    max_step_m: float,
) -> tuple[np.ndarray, dict[str, float]]:
    original = vertices.copy()
    current = vertices.copy()
    edges, edge_face_counts = mesh_edges(faces)
    boundary = np.zeros(len(vertices), dtype=bool)
    boundary_edges = edges[edge_face_counts == 1]
    boundary[boundary_edges.reshape(-1)] = True

    i0 = edges[:, 0]
    i1 = edges[:, 1]
    edge_length = np.linalg.norm(original[i1] - original[i0], axis=1)
    median_edge = float(np.median(edge_length))
    spatial_sigma = max(3.0 * median_edge, 1e-6)
    spatial_weight = np.exp(-0.5 * (edge_length / spatial_sigma) ** 2)
    feature_cos = math.cos(math.radians(feature_angle_deg))
    normal_sigma = max(1.0 - math.cos(math.radians(feature_angle_deg * 0.55)), 1e-4)

    for iteration in range(iterations):
        normals = vertex_normals(current, faces)
        normal_dot = np.einsum("ij,ij->i", normals[i0], normals[i1])
        same_surface = normal_dot >= feature_cos
        normal_weight = np.exp(-0.5 * ((1.0 - normal_dot) / normal_sigma) ** 2)
        weight = spatial_weight * normal_weight * same_surface

        weighted_sum = np.zeros_like(current)
        weight_sum = np.zeros(len(current), dtype=np.float64)
        np.add.at(weighted_sum, i0, current[i1] * weight[:, None])
        np.add.at(weighted_sum, i1, current[i0] * weight[:, None])
        np.add.at(weight_sum, i0, weight)
        np.add.at(weight_sum, i1, weight)

        movable = (weight_sum > 1e-9) & ~boundary
        target = current.copy()
        target[movable] = weighted_sum[movable] / weight_sum[movable, None]
        laplacian = target - current
        normal_distance = np.einsum("ij,ij->i", laplacian, normals)
        step = strength * normal_distance
        step = np.clip(step, -max_step_m, max_step_m)
        step[~movable] = 0.0
        current += normals * step[:, None]
        print(
            f"iteration {iteration + 1:02d}/{iterations}: "
            f"rms_step={np.sqrt(np.mean(step[movable] ** 2)) * 1000:.3f} mm "
            f"max_step={np.max(np.abs(step[movable])) * 1000:.3f} mm",
            flush=True,
        )

    displacement = np.linalg.norm(current - original, axis=1)
    stats = {
        "median_edge_mm": median_edge * 1000,
        "boundary_vertices": int(boundary.sum()),
        "rms_displacement_mm": float(np.sqrt(np.mean(displacement**2)) * 1000),
        "p95_displacement_mm": float(np.percentile(displacement, 95) * 1000),
        "max_displacement_mm": float(displacement.max() * 1000),
    }
    return current, stats


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--iterations", type=int, default=6)
    parser.add_argument("--strength", type=float, default=0.55)
    parser.add_argument("--feature-angle", type=float, default=32.0)
    parser.add_argument("--max-step-mm", type=float, default=2.0)
    args = parser.parse_args()

    if args.iterations < 1:
        parser.error("--iterations must be >= 1")
    if not 0 < args.strength <= 1:
        parser.error("--strength must be in (0, 1]")
    if not 1 <= args.feature_angle < 90:
        parser.error("--feature-angle must be in [1, 90)")
    if args.max_step_mm <= 0:
        parser.error("--max-step-mm must be > 0")

    vertices, faces = load_obj(args.input)
    print(f"mesh: {len(vertices)} vertices, {len(faces)} triangles", flush=True)
    smoothed, stats = smooth_proxy(
        vertices,
        faces,
        iterations=args.iterations,
        strength=args.strength,
        feature_angle_deg=args.feature_angle,
        max_step_m=args.max_step_mm / 1000,
    )
    write_obj(args.output, smoothed, faces)
    print("summary:", flush=True)
    for key, value in stats.items():
        print(f"  {key}: {value}", flush=True)
    print(f"wrote {args.output}", flush=True)


if __name__ == "__main__":
    main()
