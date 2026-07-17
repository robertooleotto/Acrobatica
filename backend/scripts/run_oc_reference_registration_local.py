#!/usr/bin/env python3
"""Local proof of concept: register posed photos against an OC texture reference.

The Object Capture mesh is rendered orthographically into the metric UV frame of
one reviewed plane. Candidate photos are first projected with their OC poses, then
only a small residual similarity transform is estimated from visual features.

Nothing is uploaded and no session state is changed.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
import open3d as o3d
from scipy.optimize import least_squares

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.services import ortho_bake as ob
from scripts.oc_compositing import best_view, coverage_rgba, mosaic


@dataclass
class TexturedMesh:
    vertices: np.ndarray
    faces: np.ndarray
    face_uvs: np.ndarray
    face_materials: np.ndarray
    textures: dict[int, np.ndarray]


@dataclass
class AtlasFeatures:
    points: np.ndarray
    descriptors: np.ndarray | None


def _obj_index(value: str, size: int) -> int:
    index = int(value)
    return index - 1 if index > 0 else size + index


def _load_materials(mtl_path: Path) -> tuple[dict[str, int], dict[int, np.ndarray]]:
    names: dict[str, int] = {}
    texture_paths: dict[int, Path] = {}
    current = ""
    for raw in mtl_path.read_text().splitlines():
        parts = raw.strip().split(maxsplit=1)
        if not parts:
            continue
        if parts[0] == "newmtl" and len(parts) == 2:
            current = parts[1]
            names.setdefault(current, len(names))
        elif parts[0] == "map_Kd" and len(parts) == 2 and current:
            texture_paths[names[current]] = mtl_path.parent / parts[1]
    textures = {
        material: image
        for material, path in texture_paths.items()
        if (image := cv2.imread(str(path), cv2.IMREAD_COLOR)) is not None
    }
    if not textures:
        raise RuntimeError(f"Nessuna texture leggibile in {mtl_path}")
    return names, textures


def load_textured_obj(obj_path: Path, mtl_path: Path) -> TexturedMesh:
    material_names, textures = _load_materials(mtl_path)
    vertices: list[list[float]] = []
    texcoords: list[list[float]] = []
    faces: list[list[int]] = []
    face_uvs: list[list[list[float]]] = []
    face_materials: list[int] = []
    current_material = 0

    with obj_path.open() as fh:
        for raw in fh:
            if raw.startswith("v "):
                vertices.append([float(v) for v in raw.split()[1:4]])
            elif raw.startswith("vt "):
                texcoords.append([float(v) for v in raw.split()[1:3]])
            elif raw.startswith("usemtl "):
                name = raw.split(maxsplit=1)[1].strip()
                current_material = material_names.setdefault(name, len(material_names))
            elif raw.startswith("f "):
                refs = raw.split()[1:]
                parsed: list[tuple[int, int]] = []
                for ref in refs:
                    chunks = ref.split("/")
                    vi = _obj_index(chunks[0], len(vertices))
                    ti = _obj_index(chunks[1], len(texcoords)) if len(chunks) > 1 and chunks[1] else -1
                    parsed.append((vi, ti))
                for index in range(1, len(parsed) - 1):
                    tri = [parsed[0], parsed[index], parsed[index + 1]]
                    if any(ti < 0 for _, ti in tri):
                        continue
                    faces.append([vi for vi, _ in tri])
                    face_uvs.append([texcoords[ti] for _, ti in tri])
                    face_materials.append(current_material)

    return TexturedMesh(
        np.asarray(vertices, np.float32),
        np.asarray(faces, np.int32),
        np.asarray(face_uvs, np.float32),
        np.asarray(face_materials, np.int32),
        textures,
    )


def _pixel_world(pf: ob.PlaneFrame) -> tuple[np.ndarray, np.ndarray]:
    cols, rows = np.meshgrid(np.arange(pf.tex_w), np.arange(pf.tex_h))
    gu = (cols.astype(np.float32) + 0.5) / pf.tex_w * pf.width_world
    gv = (1.0 - (rows.astype(np.float32) + 0.5) / pf.tex_h) * pf.height_world
    world = pf.origin + gu[..., None] * pf.u + gv[..., None] * pf.v
    return world.astype(np.float32), ob._polygon_mask(pf.tex_w, pf.tex_h, pf.polygon_uv)


def orient_normal(normal: np.ndarray, center: np.ndarray, cams: list[ob.Camera]) -> np.ndarray:
    n = ob._unit(np.asarray(normal, np.float64))
    direction = np.mean([cam.C - center for cam in cams], axis=0)
    return -n if float(np.dot(n, direction)) < 0 else n


def orient_frame_for_front_view(pf: ob.PlaneFrame, outward_normal: np.ndarray) -> bool:
    """Make image X point right when the plane is observed from outside."""
    screen_right = ob._unit(np.cross(pf.v, outward_normal))
    if float(np.dot(pf.u, screen_right)) >= 0:
        return False
    old_u = pf.u.copy()
    pf.origin = pf.origin + old_u * pf.width_world
    pf.u = -old_u
    pf.polygon_uv = pf.polygon_uv.copy()
    pf.polygon_uv[:, 0] = 1.0 - pf.polygon_uv[:, 0]
    return True


def render_oc_reference(
    mesh: TexturedMesh,
    pf: ob.PlaneFrame,
    normal: np.ndarray,
    depth_m: float,
    scale_m_per_mesh_unit: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    scene = getattr(mesh, "_raycast_scene", None)
    if scene is None:
        legacy = o3d.geometry.TriangleMesh(
            o3d.utility.Vector3dVector(mesh.vertices.astype(np.float64)),
            o3d.utility.Vector3iVector(mesh.faces),
        )
        scene = o3d.t.geometry.RaycastingScene()
        scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(legacy))
        mesh._raycast_scene = scene

    world, polygon = _pixel_world(pf)
    diag = float(np.linalg.norm(mesh.vertices.max(0) - mesh.vertices.min(0)))
    ray_start = max(diag * 1.2, depth_m / scale_m_per_mesh_unit * 2.0)
    points = world.reshape(-1, 3)
    origins = points + normal.astype(np.float32) * ray_start
    directions = np.repeat((-normal).astype(np.float32)[None, :], len(points), axis=0)

    primitive_ids = np.full(len(points), -1, np.int64)
    primitive_uvs = np.zeros((len(points), 2), np.float32)
    signed_depth = np.full(len(points), np.nan, np.float32)
    chunk = 500_000
    invalid_id = np.iinfo(np.uint32).max
    for start in range(0, len(points), chunk):
        end = min(start + chunk, len(points))
        rays = o3d.core.Tensor(
            np.hstack([origins[start:end], directions[start:end]]),
            dtype=o3d.core.Dtype.Float32,
        )
        hit = scene.cast_rays(rays)
        ids = hit["primitive_ids"].numpy().astype(np.int64)
        t_hit = hit["t_hit"].numpy()
        valid = (ids != invalid_id) & np.isfinite(t_hit)
        primitive_ids[start:end][valid] = ids[valid]
        primitive_uvs[start:end][valid] = hit["primitive_uvs"].numpy()[valid]
        signed_depth[start:end][valid] = (ray_start - t_hit[valid]) * scale_m_per_mesh_unit

    valid = (
        polygon.reshape(-1)
        & (primitive_ids >= 0)
        & (np.abs(signed_depth) <= depth_m)
    )
    output = np.zeros((pf.tex_h * pf.tex_w, 4), np.uint8)
    output[:, 3] = np.where(polygon.reshape(-1), 255, 0).astype(np.uint8)
    for material, texture in mesh.textures.items():
        selected = valid & (mesh.face_materials[np.maximum(primitive_ids, 0)] == material)
        rows = np.where(selected)[0]
        if len(rows) == 0:
            continue
        tri_uv = mesh.face_uvs[primitive_ids[rows]]
        bary = primitive_uvs[rows]
        uv = (
            tri_uv[:, 0] * (1.0 - bary[:, :1] - bary[:, 1:2])
            + tri_uv[:, 1] * bary[:, :1]
            + tri_uv[:, 2] * bary[:, 1:2]
        )
        map_x = (np.clip(uv[:, 0], 0.0, 1.0) * (texture.shape[1] - 1)).astype(np.float32)
        map_y = ((1.0 - np.clip(uv[:, 1], 0.0, 1.0)) * (texture.shape[0] - 1)).astype(np.float32)
        sampled = ob._sample(texture, map_x, map_y)
        output[rows, :3] = sampled

    rgba = output.reshape(pf.tex_h, pf.tex_w, 4)
    valid_mask = valid.reshape(pf.tex_h, pf.tex_w)
    depth = signed_depth.reshape(pf.tex_h, pf.tex_w)
    return rgba, valid_mask, depth


def rank_candidates(
    pf: ob.PlaneFrame,
    normal: np.ndarray,
    cams: list[ob.Camera],
    crop: float,
) -> list[dict[str, float | str]]:
    cols, rows = np.meshgrid(np.linspace(0.02, 0.98, 50), np.linspace(0.02, 0.98, 45))
    gu = cols.reshape(-1) * pf.width_world
    gv = (1.0 - rows.reshape(-1)) * pf.height_world
    points = pf.origin + gu[:, None] * pf.u + gv[:, None] * pf.v
    margin = (1.0 - crop) * 0.5
    ranked = []
    for cam in cams:
        x, y, z = ob._project(cam, points)
        to_camera = cam.C - points
        distance = np.linalg.norm(to_camera, axis=1)
        facing = (to_camera / np.maximum(distance[:, None], 1e-6)) @ normal
        valid = (
            (z > 0.01)
            & (facing > 0.15)
            & (x >= margin * cam.image_width)
            & (x <= (1.0 - margin) * cam.image_width)
            & (y >= margin * cam.image_height)
            & (y <= (1.0 - margin) * cam.image_height)
        )
        coverage = float(valid.mean())
        if coverage < 0.01:
            continue
        mean_facing = float(facing[valid].mean())
        mean_distance = float(distance[valid].mean())
        density = float(cam.fx / max(mean_distance, 1e-6))
        score = coverage * max(mean_facing, 0.0) ** 2 * math.log1p(density)
        ranked.append({
            "key": str(int(cam.key)),
            "score": round(score, 6),
            "coverage": round(coverage, 4),
            "facing": round(mean_facing, 4),
            "distance": round(mean_distance, 4),
        })
    return sorted(ranked, key=lambda item: float(item["score"]), reverse=True)


def warp_photo_to_plane(
    path: Path,
    cam: ob.Camera,
    pf: ob.PlaneFrame,
) -> tuple[np.ndarray, np.ndarray]:
    image = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if image is None:
        raise RuntimeError(f"Foto non leggibile: {path}")
    world, polygon = _pixel_world(pf)
    x, y, z = ob._project(cam, world.reshape(-1, 3))
    map_x = x.reshape(pf.tex_h, pf.tex_w).astype(np.float32)
    map_y = y.reshape(pf.tex_h, pf.tex_w).astype(np.float32)
    warped = cv2.remap(
        image, map_x, map_y, cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0),
    )
    h, w = image.shape[:2]
    mask = polygon & (z.reshape(pf.tex_h, pf.tex_w) > 0.01)
    mask &= (map_x >= 0) & (map_x < w - 1) & (map_y >= 0) & (map_y < h - 1)
    warped[~mask] = 0
    return warped, mask


def photo_coverage_mask(cam: ob.Camera, pf: ob.PlaneFrame) -> np.ndarray:
    """Copertura geometrica della foto senza leggerne o decodificarne i pixel."""
    world, polygon = _pixel_world(pf)
    x, y, z = ob._project(cam, world.reshape(-1, 3))
    map_x = x.reshape(pf.tex_h, pf.tex_w)
    map_y = y.reshape(pf.tex_h, pf.tex_w)
    return (
        polygon
        & (z.reshape(pf.tex_h, pf.tex_w) > 0.01)
        & (map_x >= 0) & (map_x < cam.image_width - 1)
        & (map_y >= 0) & (map_y < cam.image_height - 1)
    )


def _normalized_gray(image: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    return cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(gray)


def register_residual(
    reference: np.ndarray,
    reference_mask: np.ndarray,
    reference_points: list[cv2.KeyPoint],
    reference_descriptors: np.ndarray | None,
    source: np.ndarray,
    source_mask: np.ndarray,
    max_rotation_deg: float,
    max_scale_error: float,
    max_residual_px: float,
) -> tuple[np.ndarray, np.ndarray, dict[str, object]]:
    overlap = reference_mask & source_mask
    result: dict[str, object] = {"accepted": False, "reason": "dati insufficienti"}
    if int(overlap.sum()) < 8_000:
        return source, source_mask, result

    src_gray = _normalized_gray(source)
    sift = cv2.SIFT_create(nfeatures=5000, contrastThreshold=0.025, edgeThreshold=12)
    src_points, src_desc = sift.detectAndCompute(src_gray, (source_mask.astype(np.uint8) * 255))
    if (reference_descriptors is None or src_desc is None
            or len(reference_points) < 8 or len(src_points) < 8):
        result["reason"] = "feature insufficienti"
        return source, source_mask, result

    matches = cv2.BFMatcher(cv2.NORM_L2).knnMatch(src_desc, reference_descriptors, k=2)
    ratio_matches = [a for a, b in matches if a.distance < 0.72 * b.distance]
    prior_gate = max_residual_px
    prior_matches = [
        match for match in ratio_matches
        if np.linalg.norm(
            np.asarray(src_points[match.queryIdx].pt)
            - np.asarray(reference_points[match.trainIdx].pt)
        ) <= prior_gate
    ]
    result.update({
        "features_reference": len(reference_points),
        "features_source": len(src_points),
        "ratio_matches": len(ratio_matches),
        "prior_matches": len(prior_matches),
        "prior_gate_px": round(prior_gate, 3),
    })
    if len(prior_matches) < 8:
        result["reason"] = "corrispondenze compatibili con la posa insufficienti"
        return source, source_mask, result

    src_xy = np.float32([src_points[m.queryIdx].pt for m in prior_matches])
    ref_xy = np.float32([reference_points[m.trainIdx].pt for m in prior_matches])
    matrix, inlier_mask = cv2.estimateAffinePartial2D(
        src_xy, ref_xy, method=cv2.RANSAC, ransacReprojThreshold=3.0,
        maxIters=5000, confidence=0.995, refineIters=20,
    )
    if matrix is None or inlier_mask is None:
        result["reason"] = "RANSAC non convergente"
        return source, source_mask, result

    inliers = inlier_mask.reshape(-1).astype(bool)
    count = int(inliers.sum())
    ratio = count / max(len(prior_matches), 1)
    a, b = float(matrix[0, 0]), float(matrix[1, 0])
    scale = math.hypot(a, b)
    rotation = math.degrees(math.atan2(b, a))
    shift = math.hypot(float(matrix[0, 2]), float(matrix[1, 2]))
    height, width = reference.shape[:2]
    bounds = np.float32([
        [0.0, 0.0], [width - 1.0, 0.0],
        [width - 1.0, height - 1.0], [0.0, height - 1.0],
        [width * 0.5, height * 0.5],
    ])
    warped_bounds = cv2.transform(bounds[:, None, :], matrix).reshape(-1, 2)
    max_displacement = float(np.linalg.norm(warped_bounds - bounds, axis=1).max())
    predicted = cv2.transform(src_xy[inliers, None, :], matrix).reshape(-1, 2)
    prior_error = float(np.median(np.linalg.norm(src_xy[inliers] - ref_xy[inliers], axis=1))) if count else math.inf
    residual = float(np.median(np.linalg.norm(predicted - ref_xy[inliers], axis=1))) if count else math.inf
    result.update({
        "inliers": count,
        "inlier_ratio": round(ratio, 4),
        "scale": round(scale, 6),
        "rotation_deg": round(rotation, 4),
        "shift_px": round(shift, 3),
        "max_displacement_px": round(max_displacement, 3),
        "median_prior_error_px": round(prior_error, 3),
        "median_residual_px": round(residual, 3),
        "matrix": matrix.tolist(),
    })
    failures = []
    if count < 10 or ratio < 0.25:
        failures.append("pochi inlier")
    if abs(rotation) > max_rotation_deg:
        failures.append("rotazione oltre limite")
    if abs(scale - 1.0) > max_scale_error:
        failures.append("scala oltre limite")
    if max_displacement > max_residual_px:
        failures.append("spostamento residuo oltre limite")
    if residual > 2.5:
        failures.append("residuo elevato")
    if failures:
        result["reason"] = ", ".join(failures)
        return source, source_mask, result

    size = (reference.shape[1], reference.shape[0])
    aligned = cv2.warpAffine(source, matrix, size, flags=cv2.INTER_LINEAR,
                             borderMode=cv2.BORDER_CONSTANT)
    aligned_mask = cv2.warpAffine(source_mask.astype(np.uint8), matrix, size,
                                  flags=cv2.INTER_NEAREST) > 0
    result["accepted"] = True
    result["reason"] = "ok"
    return aligned, aligned_mask, result


def _overlay(reference: np.ndarray, source: np.ndarray, mask: np.ndarray) -> np.ndarray:
    output = reference.copy()
    if not mask.any():
        return output
    blended = cv2.addWeighted(reference[mask], 0.5, source[mask], 0.5, 0)
    if blended is not None:
        output[mask] = blended
    return output


def _atlas_features(image: np.ndarray, mask: np.ndarray) -> AtlasFeatures:
    sift = cv2.SIFT_create(nfeatures=3500, contrastThreshold=0.025, edgeThreshold=12)
    keypoints, descriptors = sift.detectAndCompute(
        _normalized_gray(image), mask.astype(np.uint8) * 255,
    )
    points = np.float32([point.pt for point in keypoints]) if keypoints else np.empty((0, 2), np.float32)
    return AtlasFeatures(points=points, descriptors=descriptors)


def _points_inside(points: np.ndarray, mask: np.ndarray) -> np.ndarray:
    if not len(points):
        return np.zeros(0, bool)
    x = np.clip(np.rint(points[:, 0]).astype(int), 0, mask.shape[1] - 1)
    y = np.clip(np.rint(points[:, 1]).astype(int), 0, mask.shape[0] - 1)
    return mask[y, x]


def _ratio_matches(descriptors_a: np.ndarray, descriptors_b: np.ndarray) -> dict[int, int]:
    pairs = cv2.BFMatcher(cv2.NORM_L2).knnMatch(descriptors_a, descriptors_b, k=2)
    return {
        first.queryIdx: first.trainIdx
        for pair in pairs if len(pair) == 2
        for first, second in [pair]
        if first.distance < 0.72 * second.distance
    }


def _correction_matrix(params: np.ndarray, center: tuple[float, float]) -> np.ndarray:
    dx, dy, rotation_rad, log_scale = (float(value) for value in params)
    matrix = cv2.getRotationMatrix2D(
        center, math.degrees(rotation_rad), math.exp(log_scale),
    )
    matrix[0, 2] += dx
    matrix[1, 2] += dy
    return matrix


def _apply_matrix(points: np.ndarray, matrix: np.ndarray) -> np.ndarray:
    return points @ matrix[:, :2].T + matrix[:, 2]


def _connected_components(count: int, constraints: list[dict[str, object]]) -> list[list[int]]:
    neighbours = [set() for _ in range(count)]
    for edge in constraints:
        first, second = int(edge["i"]), int(edge["j"])
        neighbours[first].add(second)
        neighbours[second].add(first)
    components: list[list[int]] = []
    unseen = set(range(count))
    while unseen:
        stack = [unseen.pop()]
        component: list[int] = []
        while stack:
            node = stack.pop()
            component.append(node)
            linked = neighbours[node] & unseen
            unseen -= linked
            stack.extend(linked)
        components.append(sorted(component))
    return components


def _reliable_pair_alignment(
    inlier_count: int,
    inlier_ratio: float,
    ransac_residual: float,
    relative_displacement: float,
    spatial_span: float,
) -> bool:
    """Allow a larger recovery only when photo-to-photo evidence is strong."""
    common = (
        inlier_count >= 10 and inlier_ratio >= 0.30
        and ransac_residual <= 2.5 and spatial_span >= 0.08
    )
    if not common:
        return False
    if relative_displacement <= 20.0:
        return True
    return bool(
        relative_displacement <= 35.0
        and inlier_count >= 40
        and ransac_residual <= 2.0 and spatial_span >= 0.25
    )


def global_align_photos(
    images: list[np.ndarray],
    masks: list[np.ndarray],
    keys: list[str],
) -> tuple[list[np.ndarray], list[np.ndarray], dict[str, object], list[dict[str, object]]]:
    count = len(images)
    identity = [{
        "offset_x": 0.0, "offset_y": 0.0,
        "rotation_deg": 0.0, "scale": 1.0,
        "matrix": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    } for _ in images]
    if count < 2:
        return images, masks, {
            "applied": False, "reason": "meno di due foto accettate",
            "pairs_considered": 0, "pairs_accepted": 0,
        }, identity

    features = [_atlas_features(image, mask) for image, mask in zip(images, masks)]
    matcher_gate = max(12.0, min(28.0, images[0].shape[1] * 0.025))
    constraints: list[dict[str, object]] = []
    pairs_considered = 0
    pair_diagnostics: list[dict[str, object]] = []

    for first in range(count):
        for second in range(first + 1, count):
            # A sparse anchored graph is enough: every photo is tied to the
            # three strongest anchors and to its three rank neighbours.
            if first >= 3 and second - first > 3:
                continue
            overlap = masks[first] & masks[second]
            overlap_pixels = int(overlap.sum())
            smaller_area = max(1, min(int(masks[first].sum()), int(masks[second].sum())))
            overlap_ratio = overlap_pixels / smaller_area
            if overlap_pixels < 5_000 or overlap_ratio < 0.04:
                continue
            pairs_considered += 1
            feature_a, feature_b = features[first], features[second]
            if feature_a.descriptors is None or feature_b.descriptors is None:
                continue
            selected_a = np.flatnonzero(_points_inside(feature_a.points, overlap))
            selected_b = np.flatnonzero(_points_inside(feature_b.points, overlap))
            if len(selected_a) < 8 or len(selected_b) < 8:
                continue

            descriptors_a = feature_a.descriptors[selected_a]
            descriptors_b = feature_b.descriptors[selected_b]
            forward = _ratio_matches(descriptors_a, descriptors_b)
            backward = _ratio_matches(descriptors_b, descriptors_a)
            mutual = [
                (query, train) for query, train in forward.items()
                if backward.get(train) == query
            ]
            if len(mutual) < 8:
                continue
            points_a = np.float32([feature_a.points[selected_a[query]] for query, _ in mutual])
            points_b = np.float32([feature_b.points[selected_b[train]] for _, train in mutual])
            prior_distance = np.linalg.norm(points_a - points_b, axis=1)
            compatible = prior_distance <= matcher_gate
            points_a, points_b = points_a[compatible], points_b[compatible]
            if len(points_a) < 8:
                continue

            relative, inlier_mask = cv2.estimateAffinePartial2D(
                points_a, points_b, method=cv2.RANSAC,
                ransacReprojThreshold=2.5, maxIters=5000,
                confidence=0.995, refineIters=20,
            )
            if relative is None or inlier_mask is None:
                continue
            inliers = inlier_mask.reshape(-1).astype(bool)
            inlier_count = int(inliers.sum())
            inlier_ratio = inlier_count / max(len(points_a), 1)
            inlier_a, inlier_b = points_a[inliers], points_b[inliers]
            predicted = _apply_matrix(inlier_a, relative)
            ransac_residual = float(np.median(np.linalg.norm(predicted - inlier_b, axis=1)))
            height, width = images[0].shape[:2]
            bounds = np.float32([
                [0.0, 0.0], [width - 1.0, 0.0],
                [width - 1.0, height - 1.0], [0.0, height - 1.0],
                [width * 0.5, height * 0.5],
            ])
            relative_displacement = float(np.linalg.norm(
                _apply_matrix(bounds, relative) - bounds, axis=1,
            ).max())
            spread = np.ptp((inlier_a + inlier_b) * 0.5, axis=0)
            spatial_span = max(spread[0] / width, spread[1] / height)
            accepted = _reliable_pair_alignment(
                inlier_count, inlier_ratio, ransac_residual,
                relative_displacement, spatial_span,
            )
            diagnostic = {
                "photo_a": keys[first], "photo_b": keys[second],
                "overlap_ratio": round(overlap_ratio, 4),
                "mutual_matches": len(mutual), "prior_matches": len(points_a),
                "inliers": inlier_count, "inlier_ratio": round(inlier_ratio, 4),
                "ransac_residual_px": round(ransac_residual, 3),
                "relative_displacement_px": round(relative_displacement, 3),
                "spatial_span": round(float(spatial_span), 4),
                "accepted": accepted,
            }
            pair_diagnostics.append(diagnostic)
            if not accepted:
                continue

            if inlier_count > 120:
                sample = np.linspace(0, inlier_count - 1, 120).astype(int)
                inlier_a, inlier_b = inlier_a[sample], inlier_b[sample]
            edge_weight = float(np.clip(
                math.sqrt(inlier_count / 25.0) * math.sqrt(overlap_ratio / 0.2),
                0.6, 2.0,
            ))
            constraints.append({
                "i": first, "j": second,
                "points_i": inlier_a.astype(np.float64),
                "points_j": inlier_b.astype(np.float64),
                "weight": edge_weight,
            })

    components = _connected_components(count, constraints)
    if not constraints:
        return images, masks, {
            "applied": False, "reason": "nessuna coppia foto-foto affidabile",
            "pairs_considered": pairs_considered, "pairs_accepted": 0,
            "components": [[keys[index] for index in component] for component in components],
            "pairs": pair_diagnostics,
        }, identity

    height, width = images[0].shape[:2]
    center = ((width - 1) * 0.5, (height - 1) * 0.5)

    def residuals(flat_params: np.ndarray) -> np.ndarray:
        params = flat_params.reshape(count, 4)
        matrices = [_correction_matrix(value, center) for value in params]
        values: list[np.ndarray] = []
        for edge in constraints:
            first, second = int(edge["i"]), int(edge["j"])
            points_i = edge["points_i"]
            points_j = edge["points_j"]
            delta = (
                _apply_matrix(points_i, matrices[first])
                - _apply_matrix(points_j, matrices[second])
            )
            values.append(delta.reshape(-1) * float(edge["weight"]) / math.sqrt(len(points_i)))
        prior_scale = np.array([6.0, 6.0, math.radians(0.20), math.log(1.012)])
        values.append((params / prior_scale).reshape(-1) * 0.75)
        # Pairwise residuals cannot observe a common translation/rotation and can
        # be reduced artificially by shrinking the whole group. Keep the group
        # gauge fixed to the OC atlas while allowing relative corrections.
        gauge_scale = np.array([0.25, 0.25, math.radians(0.01), math.log(1.001)])
        values.append(params.mean(axis=0) / gauge_scale)
        return np.concatenate(values)

    initial = np.zeros(count * 4, np.float64)
    lower_one = np.array([-20.0, -20.0, -math.radians(0.5), math.log(0.98)])
    upper_one = np.array([20.0, 20.0, math.radians(0.5), math.log(1.02)])
    result = least_squares(
        residuals, initial,
        bounds=(np.tile(lower_one, count), np.tile(upper_one, count)),
        loss="soft_l1", f_scale=1.0, max_nfev=160,
        xtol=1e-7, ftol=1e-7, gtol=1e-7,
    )
    solved = result.x.reshape(count, 4)
    solved -= solved.mean(axis=0, keepdims=True)
    matrices = [_correction_matrix(value, center) for value in solved]

    before_distances: list[np.ndarray] = []
    after_distances: list[np.ndarray] = []
    for edge in constraints:
        first, second = int(edge["i"]), int(edge["j"])
        points_i, points_j = edge["points_i"], edge["points_j"]
        before_distances.append(np.linalg.norm(points_i - points_j, axis=1))
        after_distances.append(np.linalg.norm(
            _apply_matrix(points_i, matrices[first])
            - _apply_matrix(points_j, matrices[second]),
            axis=1,
        ))
    median_before = float(np.median(np.concatenate(before_distances)))
    median_after = float(np.median(np.concatenate(after_distances)))
    improvement = median_before - median_after
    applied = bool(
        result.success and median_after < median_before
        and improvement >= max(0.05, median_before * 0.03)
    )

    if not applied:
        matrices = [np.float64([[1, 0, 0], [0, 1, 0]]) for _ in images]
        solved = np.zeros((count, 4), np.float64)

    corrected_images: list[np.ndarray] = []
    corrected_masks: list[np.ndarray] = []
    corrections: list[dict[str, object]] = []
    for image, mask, params, matrix in zip(images, masks, solved, matrices):
        corrected_images.append(cv2.warpAffine(
            image, matrix, (width, height), flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
        ))
        corrected_masks.append(cv2.warpAffine(
            mask.astype(np.uint8), matrix, (width, height),
            flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT,
        ) > 0)
        corrections.append({
            "offset_x": round(float(params[0]), 4),
            "offset_y": round(float(params[1]), 4),
            "rotation_deg": round(math.degrees(float(params[2])), 5),
            "scale": round(math.exp(float(params[3])), 7),
            "matrix": matrix.tolist(),
        })

    summary = {
        "applied": applied,
        "reason": "ok" if applied else "miglioramento globale non sufficiente",
        "pairs_considered": pairs_considered,
        "pairs_accepted": len(constraints),
        "matched_points": int(sum(len(edge["points_i"]) for edge in constraints)),
        "median_pair_error_before_px": round(median_before, 4),
        "median_pair_error_after_px": round(median_after if applied else median_before, 4),
        "optimizer_evaluations": int(result.nfev),
        "components": [[keys[index] for index in component] for component in components],
        "pairs": pair_diagnostics,
    }
    return corrected_images, corrected_masks, summary, corrections


def _photo_path(directory: Path, key: str) -> Path | None:
    for suffix in (".jpg", ".jpeg", ".png", ".JPG"):
        path = directory / f"{int(key):04d}{suffix}"
        if path.exists():
            return path
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mesh", type=Path, required=True)
    parser.add_argument("--mtl", type=Path, required=True)
    parser.add_argument("--planes", type=Path, required=True)
    parser.add_argument("--poses", type=Path, required=True)
    parser.add_argument("--photos", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--plane-id", type=int, default=4)
    parser.add_argument("--texel-mm", type=float, default=20.0)
    parser.add_argument("--scale", type=float, default=6.0927)
    parser.add_argument("--depth-m", type=float, default=2.0)
    parser.add_argument("--max-photos", type=int, default=20)
    parser.add_argument("--coverage-photos", type=int, default=60)
    parser.add_argument("--max-residual-px", type=float, default=40.0)
    parser.add_argument("--max-rotation-deg", type=float, default=0.5)
    parser.add_argument("--max-scale-error", type=float, default=0.03)
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    poses = json.loads(args.poses.read_text())
    cams = ob.load_cameras(poses)
    doc = json.loads(args.planes.read_text())
    plane = next((p for p in doc.get("planes", []) if int(p.get("id", -1)) == args.plane_id), None)
    if plane is None:
        raise SystemExit(f"Piano {args.plane_id} non trovato")
    vertices, faces = ob.load_obj(args.mesh)
    pf = ob.plane_frame(
        plane, np.array([0.0, 1.0, 0.0]), vertices, faces,
        args.texel_mm / 1000.0, args.scale,
    )
    if pf is None:
        raise SystemExit("Impossibile costruire il frame del piano")
    normal = orient_normal(np.asarray(plane["normale"]), pf.corners.mean(0), cams)
    horizontal_flipped = orient_frame_for_front_view(pf, normal)

    print(f"Carico mesh OC texturizzata: {args.mesh.name}")
    textured_mesh = load_textured_obj(args.mesh, args.mtl)
    print(f"Bake riferimento OC {pf.tex_w}x{pf.tex_h}...")
    reference_rgba, reference_mask, depth = render_oc_reference(
        textured_mesh, pf, normal, args.depth_m, args.scale,
    )
    reference = reference_rgba[..., :3]
    cv2.imwrite(str(args.out / "01_oc_reference.png"), reference_rgba)
    depth_vis = np.zeros_like(reference)
    valid_depth = np.isfinite(depth) & reference_mask
    if valid_depth.any():
        lo, hi = np.percentile(depth[valid_depth], [2, 98])
        normalized = np.zeros_like(depth)
        normalized[valid_depth] = np.clip(
            (depth[valid_depth] - lo) / max(hi - lo, 1e-6), 0, 1)
        depth_vis = cv2.applyColorMap((normalized * 255).astype(np.uint8), cv2.COLORMAP_TURBO)
        depth_vis[~valid_depth] = 0
    cv2.imwrite(str(args.out / "02_oc_depth.png"), depth_vis)

    ranked = rank_candidates(pf, normal, cams, crop=0.9)
    camera_by_key = {str(int(cam.key)): cam for cam in cams}
    accepted_images: list[np.ndarray] = []
    accepted_masks: list[np.ndarray] = []
    accepted_full_masks: list[np.ndarray] = []
    accepted_items: list[dict[str, object]] = []
    accepted_stems: list[str] = []
    accepted_keys: list[str] = []
    photo_reports: list[dict[str, object]] = []
    planar_reference = reference_mask & np.isfinite(depth) & (np.abs(depth) <= 0.35)
    cv2.imwrite(str(args.out / "02b_planar_mask.png"), planar_reference.astype(np.uint8) * 255)
    can_register = int(planar_reference.sum()) >= 8_000
    if can_register:
        registration_sift = cv2.SIFT_create(
            nfeatures=5000, contrastThreshold=0.025, edgeThreshold=12,
        )
        reference_points, reference_descriptors = registration_sift.detectAndCompute(
            _normalized_gray(reference), planar_reference.astype(np.uint8) * 255,
        )
    else:
        reference_points, reference_descriptors = [], None

    registration_candidates = ranked[:args.max_photos] if can_register else []
    for rank, candidate in enumerate(registration_candidates, 1):
        key = str(candidate["key"])
        path = _photo_path(args.photos, key)
        item: dict[str, object] = {"rank": rank, **candidate, "photo_found": path is not None}
        if path is None:
            photo_reports.append(item)
            continue
        print(f"Foto {key}: proiezione e registrazione")
        posed, posed_mask = warp_photo_to_plane(path, camera_by_key[key], pf)
        aligned, aligned_mask, registration = register_residual(
            reference, planar_reference, reference_points, reference_descriptors,
            posed, posed_mask,
            max_rotation_deg=args.max_rotation_deg,
            max_scale_error=args.max_scale_error,
            max_residual_px=args.max_residual_px,
        )
        item["registration"] = registration
        stem = f"photo_{rank:02d}_{int(key):04d}"
        cv2.imwrite(str(args.out / f"{stem}_posed.png"), posed)
        overlap_before = planar_reference & posed_mask
        cv2.imwrite(str(args.out / f"{stem}_overlay_before.png"),
                    _overlay(reference, posed, overlap_before))
        if bool(registration["accepted"]):
            planar_aligned_mask = aligned_mask & planar_reference
            cv2.imwrite(str(args.out / f"{stem}_aligned_reference.png"), aligned)
            cv2.imwrite(str(args.out / f"{stem}_overlay_reference.png"),
                        _overlay(reference, aligned, planar_aligned_mask))
            cv2.imwrite(str(args.out / f"{stem}_aligned.png"), aligned)
            cv2.imwrite(str(args.out / f"{stem}_aligned_mask.png"),
                        planar_aligned_mask.astype(np.uint8) * 255)
            overlap_after = planar_aligned_mask
            cv2.imwrite(str(args.out / f"{stem}_overlay_after.png"),
                        _overlay(reference, aligned, overlap_after))
            accepted_images.append(aligned)
            accepted_masks.append(planar_aligned_mask)
            accepted_full_masks.append(aligned_mask)
            accepted_items.append(item)
            accepted_stems.append(stem)
            accepted_keys.append(key)
        photo_reports.append(item)

    print("Allineamento globale tra foto...")
    accepted_images, accepted_masks, global_alignment, global_corrections = global_align_photos(
        accepted_images, accepted_masks, accepted_keys,
    )
    accepted_masks = [mask & planar_reference for mask in accepted_masks]
    size = (reference.shape[1], reference.shape[0])
    compositing_masks = [
        cv2.warpAffine(
            mask.astype(np.uint8), np.asarray(correction["matrix"], np.float64), size,
            flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT,
        ) > 0
        for mask, correction in zip(accepted_full_masks, global_corrections)
    ]
    for image, alignment_mask, compositing_mask, item, stem, correction in zip(
        accepted_images, accepted_masks, compositing_masks,
        accepted_items, accepted_stems, global_corrections,
    ):
        registration = item.get("registration")
        if isinstance(registration, dict):
            registration["global_correction"] = correction
        cv2.imwrite(str(args.out / f"{stem}_aligned.png"), image)
        cv2.imwrite(str(args.out / f"{stem}_aligned_mask.png"),
                    compositing_mask.astype(np.uint8) * 255)
        cv2.imwrite(str(args.out / f"{stem}_overlay_after.png"),
                    _overlay(reference, image, alignment_mask))

    coverage_union = np.zeros(reference.shape[:2], bool)
    for mask in compositing_masks:
        coverage_union |= mask
    coverage_limit = max(args.max_photos, args.coverage_photos)
    filler_start = args.max_photos if accepted_images else 0
    for rank, candidate in enumerate(
        ranked[filler_start:coverage_limit], filler_start + 1,
    ):
        key = str(candidate["key"])
        cam = camera_by_key[key]
        predicted_mask = photo_coverage_mask(cam, pf)
        new_pixels = predicted_mask & ~coverage_union
        if int(new_pixels.sum()) < 200:
            continue
        path = _photo_path(args.photos, key)
        if path is None:
            continue
        posed, posed_mask = warp_photo_to_plane(path, cam, pf)
        print(f"Foto {key}: riempimento copertura da posa")
        identity_correction = {
            "offset_x": 0.0, "offset_y": 0.0,
            "rotation_deg": 0.0, "scale": 1.0,
            "matrix": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
        }
        registration = {
            "accepted": True,
            "reason": "riempimento copertura da posa",
            "pose_only_filler": True,
            "matrix": identity_correction["matrix"],
            "global_correction": identity_correction,
        }
        item = {
            "rank": rank, **candidate, "photo_found": True,
            "registration": registration,
        }
        stem = f"photo_{rank:02d}_{int(key):04d}"
        cv2.imwrite(str(args.out / f"{stem}_posed.png"), posed)
        cv2.imwrite(str(args.out / f"{stem}_aligned.png"), posed)
        cv2.imwrite(str(args.out / f"{stem}_aligned_mask.png"),
                    posed_mask.astype(np.uint8) * 255)
        cv2.imwrite(str(args.out / f"{stem}_overlay_before.png"),
                    _overlay(reference, posed, posed_mask & planar_reference))
        cv2.imwrite(str(args.out / f"{stem}_overlay_after.png"),
                    _overlay(reference, posed, posed_mask & planar_reference))
        accepted_images.append(posed)
        compositing_masks.append(posed_mask)
        existing = next(
            (report for report in photo_reports if str(report.get("key")) == key),
            None,
        )
        if existing is None:
            photo_reports.append(item)
        else:
            existing.update(item)
        coverage_union |= posed_mask

    registered_mosaic = mosaic(accepted_images, compositing_masks, reference)
    registered_best_view = best_view(accepted_images, compositing_masks, reference)
    cv2.imwrite(str(args.out / "03_registered_mosaic_blend.png"),
                coverage_rgba(registered_mosaic, compositing_masks))
    cv2.imwrite(str(args.out / "04_registered_best_view.png"),
                coverage_rgba(registered_best_view, compositing_masks))
    registered_union = np.zeros(reference_mask.shape, bool)
    for mask in compositing_masks:
        registered_union |= mask
    coverage_target = planar_reference
    if not coverage_target.any():
        coverage_target = ob._polygon_mask(pf.tex_w, pf.tex_h, pf.polygon_uv)
    accepted_regs = [
        item["registration"] for item in photo_reports
        if isinstance(item.get("registration"), dict)
        and bool(item["registration"].get("accepted"))
    ]
    registration_summary = {}
    summary_fields = {
        "prior_error_px_median": "median_prior_error_px",
        "residual_px_median": "median_residual_px",
        "scale_median": "scale",
        "rotation_deg_median": "rotation_deg",
        "shift_px_median": "shift_px",
        "max_displacement_px_median": "max_displacement_px",
    }
    for name, field in summary_fields.items():
        values = [float(item[field]) for item in accepted_regs if field in item]
        if values:
            registration_summary[name] = round(float(np.median(values)), 4)
    report = {
        "plane_id": args.plane_id,
        "plane_name": plane.get("nome", ""),
        "size_px": [pf.tex_w, pf.tex_h],
        "size_m": [round(pf.width_m, 3), round(pf.height_m, 3)],
        "texel_mm": args.texel_mm,
        "horizontal_flipped_for_front_view": horizontal_flipped,
        "registration_limits": {
            "max_residual_px": args.max_residual_px,
            "max_rotation_deg": args.max_rotation_deg,
            "max_scale_error": args.max_scale_error,
        },
        "oc_reference_coverage": round(float(reference_mask.mean()), 4),
        "planar_reference_coverage": round(float(planar_reference.mean()), 4),
        "registered_planar_coverage": round(
            float(registered_union[coverage_target].mean()) if coverage_target.any() else 0.0,
            4,
        ),
        "accepted_photos": len(accepted_images),
        "global_alignment": global_alignment,
        "registration_summary": registration_summary,
        "candidates": ranked,
        "photos": photo_reports,
    }
    (args.out / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps({k: report[k] for k in (
        "plane_name", "size_px", "oc_reference_coverage", "accepted_photos"
    )}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
