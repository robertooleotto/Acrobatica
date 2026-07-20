"""Similarity frame used only while analysing Object Capture geometry."""
import json
import math

import numpy as np


def umeyama_similarity(source, target):
    """Return scale, rotation and translation with s*R*source+t ~= target."""
    source = np.asarray(source, dtype=float)
    target = np.asarray(target, dtype=float)
    if source.shape != target.shape or source.ndim != 2 or source.shape[1] != 3:
        raise ValueError("centri camera non compatibili")
    if len(source) < 3:
        raise ValueError("servono almeno tre pose comuni")
    source_mean = source.mean(axis=0)
    target_mean = target.mean(axis=0)
    source_centered = source - source_mean
    target_centered = target - target_mean
    covariance = source_centered.T @ target_centered / len(source)
    u, singular, vt = np.linalg.svd(covariance)
    handedness = np.sign(np.linalg.det(vt.T @ u.T))
    rotation = vt.T @ np.diag([1.0, 1.0, handedness]) @ u.T
    variance = float(np.sum(source_centered * source_centered) / len(source))
    if variance <= 1e-12:
        raise ValueError("centri camera OC degeneri")
    scale = float(np.dot(singular, [1.0, 1.0, handedness]) / variance)
    translation = target_mean - scale * (rotation @ source_mean)
    return scale, rotation, translation


def _arkit_center(photo):
    metadata = photo.get("metadata") or photo
    values = metadata.get("camera_transform")
    if not isinstance(values, list) or len(values) != 16:
        return None
    transform = np.asarray(values, dtype=float).reshape(4, 4, order="F")
    return transform[:3, 3]


def estimate_oc_to_arkit(oc_poses, photos):
    """Estimate a robust OC-to-ARKit similarity from matching camera centers."""
    arkit = {}
    for photo in photos:
        center = _arkit_center(photo)
        if center is not None:
            arkit[int(photo["order_index"])] = center

    source = []
    target = []
    for key, pose in oc_poses.items():
        try:
            index = int(key)
        except (TypeError, ValueError):
            continue
        center = pose.get("translation") if isinstance(pose, dict) else None
        if index not in arkit or not isinstance(center, list) or len(center) != 3:
            continue
        source.append(center)
        target.append(arkit[index])
    if len(source) < 3:
        raise ValueError(f"pose OC/ARKit comuni insufficienti: {len(source)}")

    source = np.asarray(source, dtype=float)
    target = np.asarray(target, dtype=float)
    scale, rotation, translation = umeyama_similarity(source, target)
    transformed = scale * (rotation @ source.T).T + translation
    residuals = np.linalg.norm(transformed - target, axis=1)
    median = float(np.median(residuals))
    threshold = max(0.12, median * 4.0)
    inliers = residuals <= threshold
    if int(inliers.sum()) >= max(3, math.ceil(len(source) * 0.60)):
        scale, rotation, translation = umeyama_similarity(source[inliers], target[inliers])
        transformed = scale * (rotation @ source.T).T + translation
        residuals = np.linalg.norm(transformed - target, axis=1)
    if not math.isfinite(scale) or scale <= 0:
        raise ValueError("scala OC/ARKit non valida")
    percentile_95 = float(np.percentile(residuals, 95))
    if float(residuals.mean()) > 0.20 or percentile_95 > 0.50:
        raise ValueError(
            "allineamento OC/ARKit incoerente: "
            f"media {residuals.mean():.3f} m, p95 {percentile_95:.3f} m")

    matrix = np.eye(4)
    matrix[:3, :3] = scale * rotation
    matrix[:3, 3] = translation
    return {
        "schema": "acro.oc_to_analysis/v1",
        "scale": scale,
        "R": rotation.tolist(),
        "t": translation.tolist(),
        "matrix_row_major": matrix.tolist(),
        "pairs": len(source),
        "inliers": int(inliers.sum()),
        "mean_error_m": float(residuals.mean()),
        "p95_error_m": percentile_95,
        "max_error_m": float(residuals.max()),
    }


def load_similarity(path_or_document):
    document = (json.load(open(path_or_document))
                if isinstance(path_or_document, (str, bytes)) else path_or_document)
    return (
        float(document["scale"]),
        np.asarray(document["R"], dtype=float),
        np.asarray(document["t"], dtype=float),
    )


def transform_point(point, scale, rotation, translation):
    return (scale * (rotation @ np.asarray(point, dtype=float)) + translation).tolist()


def inverse_point(point, scale, rotation, translation):
    return (rotation.T @ ((np.asarray(point, dtype=float) - translation) / scale)).tolist()


def inverse_normal(normal, rotation):
    value = rotation.T @ np.asarray(normal, dtype=float)
    length = float(np.linalg.norm(value))
    return (value / length).tolist() if length > 1e-12 else value.tolist()
