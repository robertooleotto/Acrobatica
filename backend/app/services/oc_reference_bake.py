"""Bake dei piani usando la texture Object Capture come atlante metrico.

Le pose OC forniscono la proiezione iniziale. Ogni foto viene poi registrata con
una piccola trasformazione residua contro il bake OC e, infine, tutte le foto
accettate vengono ottimizzate insieme sulle loro sovrapposizioni. Il compositing
mantiene una sola sorgente dominante e sfuma soltanto una fascia stretta sui
bordi, evitando la perdita di nitidezza del blending medio.
"""
from __future__ import annotations

import gc
import json
import math
import os
from pathlib import Path

import cv2
import numpy as np

from . import ortho_bake as ob
from scripts import run_oc_reference_registration_local as registration
from scripts.oc_compositing import coverage_rgba, mosaic


def _write_texture_png(path: str, bgra: np.ndarray) -> None:
    """Scrive il buffer OpenCV BGRA senza reinterpretarne i canali."""
    if not cv2.imwrite(path, bgra):
        raise RuntimeError(f"Impossibile scrivere la texture: {path}")


def _identity_correction() -> dict[str, object]:
    return {
        "offset_x": 0.0,
        "offset_y": 0.0,
        "rotation_deg": 0.0,
        "scale": 1.0,
        "matrix": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    }


def _stable_mosaic_anchor(
    accepted_keys: list[str],
    ranked: list[dict],
    score_ratio: float = 0.995,
) -> str | None:
    """Sceglie una vista dominante stabile fra candidate quasi equivalenti.

    Il mosaico congela la prima sorgente su gran parte del piano. Piccole
    variazioni del piano non devono quindi scambiare due foto con score quasi
    identico: nel gruppo vicino al best score preferiamo la copertura maggiore,
    che tende anche a essere la vista piu centrale dell'intera facciata.
    """
    accepted = set(accepted_keys)
    candidates = [item for item in ranked if str(item.get("key")) in accepted]
    if not candidates:
        return None
    best_score = max(float(item.get("score", 0.0)) for item in candidates)
    near_best = [
        item for item in candidates
        if float(item.get("score", 0.0)) >= best_score * score_ratio
    ]
    anchor = max(
        near_best,
        key=lambda item: (
            float(item.get("coverage", 0.0)),
            float(item.get("facing", 0.0)),
            float(item.get("score", 0.0)),
        ),
    )
    return str(anchor["key"])


def _estimate_planar_seam_affine(
    target: np.ndarray,
    target_mask: np.ndarray,
    target_coverage: np.ndarray,
    source: np.ndarray,
    source_mask: np.ndarray,
    source_coverage: np.ndarray,
) -> tuple[np.ndarray | None, dict[str, object]]:
    """Stima un affine locale usando soltanto la superficie del muro."""
    overlap = target_mask & source_mask
    report: dict[str, object] = {
        "accepted": False,
        "overlap_pixels": int(overlap.sum()),
        "reason": "sovrapposizione planare insufficiente",
    }
    minimum_pixels = max(1_000, int(overlap.size * 0.05))
    if int(overlap.sum()) < minimum_pixels:
        return None, report

    sift = cv2.SIFT_create(
        nfeatures=10_000, contrastThreshold=0.02, edgeThreshold=12,
    )
    target_points, target_descriptors = sift.detectAndCompute(
        registration._normalized_gray(target), overlap.astype(np.uint8) * 255,
    )
    source_points, source_descriptors = sift.detectAndCompute(
        registration._normalized_gray(source), overlap.astype(np.uint8) * 255,
    )
    if (target_descriptors is None or source_descriptors is None
            or len(target_points) < 20 or len(source_points) < 20):
        report["reason"] = "feature planari insufficienti"
        return None, report

    matcher = cv2.BFMatcher(cv2.NORM_L2)

    def ratio_matches(first: np.ndarray, second: np.ndarray) -> dict[int, int]:
        return {
            match.queryIdx: match.trainIdx
            for pair in matcher.knnMatch(first, second, k=2)
            if len(pair) == 2
            for match, alternative in [pair]
            if match.distance < 0.72 * alternative.distance
        }

    forward = ratio_matches(source_descriptors, target_descriptors)
    backward = ratio_matches(target_descriptors, source_descriptors)
    mutual = [
        (query, train) for query, train in forward.items()
        if backward.get(train) == query
    ]
    if len(mutual) < 20:
        report["reason"] = "corrispondenze planari insufficienti"
        return None, report

    source_xy = np.float32([
        source_points[query].pt for query, _ in mutual
    ])
    target_xy = np.float32([
        target_points[train].pt for _, train in mutual
    ])
    prior_distance = np.linalg.norm(source_xy - target_xy, axis=1)
    compatible = prior_distance <= 35.0
    source_xy, target_xy = source_xy[compatible], target_xy[compatible]
    if len(source_xy) < 20:
        report["reason"] = "corrispondenze compatibili insufficienti"
        return None, report

    height, width = overlap.shape
    bounds = np.float32([
        [0.0, 0.0], [width - 1.0, 0.0],
        [width - 1.0, height - 1.0], [0.0, height - 1.0],
        [width * 0.5, height * 0.5],
    ])
    displacement_limit = max(8.0, min(height, width) * 0.025)

    target_gray = registration._normalized_gray(target).astype(np.float32)
    target_gx = cv2.Sobel(target_gray, cv2.CV_32F, 1, 0, ksize=3)
    target_gy = cv2.Sobel(target_gray, cv2.CV_32F, 0, 1, ksize=3)
    distance_inside = cv2.distanceTransform(
        target_coverage.astype(np.uint8), cv2.DIST_L2, 3,
    )

    def seam_score(matrix: np.ndarray) -> float:
        size = (width, height)
        warped = cv2.warpAffine(
            source, matrix, size, flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
        )
        warped_coverage = cv2.warpAffine(
            source_coverage.astype(np.uint8), matrix, size,
            flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT,
        ) > 0
        band = (
            target_coverage & warped_coverage
            & (distance_inside > 2.0) & (distance_inside <= 25.0)
        )
        if int(band.sum()) < minimum_pixels // 4:
            return float("inf")
        source_gray = registration._normalized_gray(warped).astype(np.float32)
        source_gx = cv2.Sobel(source_gray, cv2.CV_32F, 1, 0, ksize=3)
        source_gy = cv2.Sobel(source_gray, cv2.CV_32F, 0, 1, ksize=3)
        gradient_error = np.sqrt(
            (target_gx[band] - source_gx[band]) ** 2
            + (target_gy[band] - source_gy[band]) ** 2
        )
        return float(np.median(gradient_error))

    identity = np.float64([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])
    identity_score = seam_score(identity)
    candidates: list[tuple[float, np.ndarray, dict[str, object]]] = []
    candidate_reports: list[dict[str, object]] = []
    for threshold in (1.5, 2.0, 2.25):
        cv2.setRNGSeed(0)
        matrix, inlier_mask = cv2.estimateAffine2D(
            source_xy, target_xy, method=cv2.RANSAC,
            ransacReprojThreshold=threshold, maxIters=15_000,
            confidence=0.999, refineIters=50,
        )
        if matrix is None or inlier_mask is None:
            continue
        inliers = inlier_mask.reshape(-1).astype(bool)
        predicted = source_xy @ matrix[:, :2].T + matrix[:, 2]
        before = np.linalg.norm(source_xy - target_xy, axis=1)[inliers]
        after = np.linalg.norm(predicted - target_xy, axis=1)[inliers]
        singular_values = np.linalg.svd(matrix[:, :2], compute_uv=False)
        moved = bounds @ matrix[:, :2].T + matrix[:, 2]
        max_displacement = float(np.linalg.norm(moved - bounds, axis=1).max())
        median_before = float(np.median(before)) if len(before) else float("inf")
        median_after = float(np.median(after)) if len(after) else float("inf")
        inlier_count = int(inliers.sum())
        inlier_ratio = inlier_count / max(len(source_xy), 1)
        score = seam_score(matrix)
        safe = bool(
            inlier_count >= 50 and inlier_ratio >= 0.25
            and median_after <= 1.5
            and median_after <= median_before * 0.65
            and float(singular_values.min()) >= 0.97
            and float(singular_values.max()) <= 1.03
            and float(np.linalg.det(matrix[:, :2])) > 0.0
            and max_displacement <= displacement_limit
        )
        item = {
            "ransac_threshold_px": threshold,
            "safe": safe,
            "inliers": inlier_count,
            "inlier_ratio": round(inlier_ratio, 4),
            "median_before_px": round(median_before, 4),
            "median_after_px": round(median_after, 4),
            "scale_min": round(float(singular_values.min()), 6),
            "scale_max": round(float(singular_values.max()), 6),
            "max_displacement_px": round(max_displacement, 4),
            "seam_gradient_error": round(score, 4),
        }
        candidate_reports.append(item)
        if safe and np.isfinite(score):
            candidates.append((score, matrix, item))

    report.update({
        "matches": len(source_xy),
        "seam_gradient_error_before": round(identity_score, 4),
        "candidates": candidate_reports,
    })
    if not candidates:
        report["reason"] = "nessun affine planare entro soglia"
        return None, report

    score, matrix, selected = min(candidates, key=lambda candidate: candidate[0])
    if score > identity_score * 0.90:
        report["reason"] = "raccordo sul bordo non migliorato"
        return None, report
    report.update({
        **selected,
        "accepted": True,
        "reason": "ok",
        "seam_gradient_error_after": round(score, 4),
        "matrix": matrix.tolist(),
    })
    return matrix, report


def _refine_major_seams(
    images: list[np.ndarray],
    planar_masks: list[np.ndarray],
    full_masks: list[np.ndarray],
    keys: list[str],
) -> tuple[list[np.ndarray], list[np.ndarray], list[np.ndarray], list[dict]]:
    """Allinea localmente solo le espansioni grandi del mosaico."""
    if not images:
        return images, planar_masks, full_masks, []

    refined_images = [image.copy() for image in images]
    refined_planar = [mask.copy() for mask in planar_masks]
    refined_full = [mask.copy() for mask in full_masks]
    height, width = full_masks[0].shape
    major_pixels = max(1_000, int(height * width * 0.05))
    covered = np.zeros((height, width), bool)
    planar_covered = np.zeros((height, width), bool)
    target = np.zeros_like(images[0])
    remaining = list(range(len(images)))
    reports: list[dict] = []

    while remaining:
        contributions = [
            int((refined_full[index] & ~covered).sum()) for index in remaining
        ]
        if not covered.any():
            selected_at = 0
        else:
            scores = [
                contribution / (1.0 + index * 0.08)
                for contribution, index in zip(contributions, remaining)
            ]
            selected_at = int(np.argmax(scores))
        if contributions[selected_at] == 0:
            break
        selected = remaining.pop(selected_at)

        if covered.any() and contributions[selected_at] >= major_pixels:
            matrix, item = _estimate_planar_seam_affine(
                target, planar_covered, covered,
                refined_images[selected], refined_planar[selected],
                refined_full[selected],
            )
            item.update({
                "key": keys[selected],
                "new_pixels_before": contributions[selected_at],
            })
            reports.append(item)
            if matrix is not None:
                size = (width, height)
                refined_images[selected] = cv2.warpAffine(
                    refined_images[selected], matrix, size,
                    flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT,
                )
                refined_planar[selected] = cv2.warpAffine(
                    refined_planar[selected].astype(np.uint8), matrix, size,
                    flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT,
                ) > 0
                refined_full[selected] = cv2.warpAffine(
                    refined_full[selected].astype(np.uint8), matrix, size,
                    flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT,
                ) > 0

        new_pixels = refined_full[selected] & ~covered
        target[new_pixels] = refined_images[selected][new_pixels]
        covered |= refined_full[selected]
        planar_covered |= refined_planar[selected]

    return refined_images, refined_planar, refined_full, reports


def adaptive_registration_budget(
    pf: ob.PlaneFrame,
    base_photos: int = 20,
    max_photos: int = 80,
) -> int:
    """Dimensiona il tetto lasciando spazio a viste che chiudono i bordi.

    ``base_photos`` sono le viste principali ordinate per qualita. Il 50% di
    headroom non viene riempito automaticamente: `_select_registration_candidates`
    lo usa solo per foto che aumentano davvero la copertura singola/doppia.
    """
    span_need = math.ceil(pf.width_m / 3.0)
    area_need = math.ceil(pf.area_m2 / 40.0)
    coverage_headroom = math.ceil(base_photos * 1.5)
    return min(max_photos, max(coverage_headroom, span_need, area_need))


def _alignment_is_connected(report: dict, photo_count: int) -> bool:
    """Verifica che tutte le foto registrate appartengano allo stesso grafo."""
    if photo_count < 2:
        return False
    components = report.get("components")
    if isinstance(components, list):
        return len(components) == 1
    # Mantiene compatibilita con implementazioni/test che non espongono ancora
    # il dettaglio dei componenti ma dichiarano l'allineamento applicato.
    return bool(report.get("applied"))


def _dominant_component_keys(report: dict, accepted_keys: list[str]) -> set[str]:
    """Restituisce la catena foto-foto piu estesa, escludendo le isole."""
    components = report.get("components")
    if isinstance(components, list) and components:
        valid = [component for component in components if component]
        if valid:
            return {str(key) for key in max(valid, key=len)}
    if report.get("applied"):
        return set(accepted_keys)
    return set()


def _pose_filler_candidates(
    ranked: list[dict],
    attempted_keys: set[str],
    accepted_keys: set[str],
    limit: int,
):
    """Con foto valide, non ricicla come filler registrazioni gia rifiutate."""
    for rank, candidate in enumerate(ranked[:limit], 1):
        key = str(candidate["key"])
        if key in accepted_keys:
            continue
        if accepted_keys and key in attempted_keys:
            continue
        yield rank, candidate


def _select_registration_candidates(
    pf: ob.PlaneFrame,
    normal: np.ndarray,
    cams: list[ob.Camera],
    ranked: list[dict],
    *,
    crop: float,
    base_photos: int,
    max_photos: int,
) -> tuple[list[dict], dict]:
    """Seleziona viste distribuite finche il piano ha due coperture frontali."""
    budget = adaptive_registration_budget(pf, base_photos, max_photos)
    if not ranked or budget <= 0:
        return [], {"budget": budget, "selected": 0}

    grid_w = min(180, max(24, int(math.ceil(pf.width_m / 0.25))))
    grid_h = min(180, max(24, int(math.ceil(pf.height_m / 0.25))))
    cols, rows = np.meshgrid(np.arange(grid_w), np.arange(grid_h))
    gu = (cols.reshape(-1) + 0.5) / grid_w * pf.width_world
    gv = (1.0 - (rows.reshape(-1) + 0.5) / grid_h) * pf.height_world
    world = pf.origin + gu[:, None] * pf.u + gv[:, None] * pf.v
    polygon = ob._polygon_mask(grid_w, grid_h, pf.polygon_uv).reshape(-1)
    polygon_cells = max(int(polygon.sum()), 1)
    quality_margin = max((1.0 - crop) * 0.5, 0.12)
    camera_by_key = {str(int(cam.key)): cam for cam in cams}
    masks: list[np.ndarray] = []
    usable_ranked: list[dict] = []
    n = ob._unit(np.asarray(normal, float))

    for candidate in ranked[:120]:
        cam = camera_by_key.get(str(candidate["key"]))
        if cam is None:
            continue
        x, y, z = ob._project(cam, world)
        to_camera = cam.C - world
        distance = np.linalg.norm(to_camera, axis=1)
        facing = (to_camera / np.maximum(distance[:, None], 1e-6)) @ n
        mask = (
            polygon
            & (z > 0.01)
            & (facing >= 0.342)
            & (x >= quality_margin * cam.image_width)
            & (x <= (1.0 - quality_margin) * cam.image_width)
            & (y >= quality_margin * cam.image_height)
            & (y <= (1.0 - quality_margin) * cam.image_height)
        )
        if mask.any():
            usable_ranked.append(candidate)
            masks.append(mask)

    # Il viewer locale parte dalle viste meglio classificate e su questa
    # sequenza costruisce un grafo molto stabile. Manteniamo lo stesso nucleo;
    # le viste distribuite servono solo ad ampliare la copertura quando occorre.
    selected = list(ranked[:min(base_photos, budget, len(ranked))])
    selected_keys = {str(candidate["key"]) for candidate in selected}
    selected_ids = {
        index for index, candidate in enumerate(usable_ranked)
        if str(candidate["key"]) in selected_keys
    }
    coverage_count = np.zeros(len(world), np.uint8)
    for index in selected_ids:
        coverage_count[masks[index]] += 1

    while len(selected) < min(budget, len(usable_ranked)):
        deficit = polygon & (coverage_count < 2)
        best_index = -1
        best_gain = -1
        best_overlap = -1
        covered = coverage_count > 0
        for index, mask in enumerate(masks):
            if index in selected_ids:
                continue
            gain = int((mask & deficit).sum())
            overlap = int((mask & covered).sum()) if selected else 0
            if gain > best_gain or (gain == best_gain and overlap > best_overlap):
                best_index, best_gain, best_overlap = index, gain, overlap
        if best_index < 0:
            break
        single_coverage = float((coverage_count[polygon] >= 1).mean())
        double_coverage = float((coverage_count[polygon] >= 2).mean())
        if single_coverage >= 0.995 and double_coverage >= 0.95:
            break
        if best_gain < max(1, int(polygon_cells * 0.002)):
            break
        selected_ids.add(best_index)
        candidate = usable_ranked[best_index]
        selected.append(candidate)
        selected_keys.add(str(candidate["key"]))
        coverage_count[masks[best_index]] += 1

    # Mantiene il baseline anche quando le maschere centrali sono troppo severe.
    for candidate in ranked:
        if len(selected) >= min(base_photos, len(ranked)) or len(selected) >= budget:
            break
        if str(candidate["key"]) not in selected_keys:
            selected.append(candidate)
            selected_keys.add(str(candidate["key"]))

    single_coverage = float((coverage_count[polygon] >= 1).mean())
    double_coverage = float((coverage_count[polygon] >= 2).mean())
    rank_order = {str(candidate["key"]): index for index, candidate in enumerate(ranked)}
    selected.sort(key=lambda candidate: rank_order.get(str(candidate["key"]), len(ranked)))
    return selected, {
        "budget": budget,
        "selected": len(selected),
        "single_coverage": round(single_coverage, 4),
        "double_coverage": round(double_coverage, 4),
        "grid": [grid_w, grid_h],
    }


def _compose_plane(
    textured_mesh: registration.TexturedMesh,
    pf: ob.PlaneFrame,
    plane: dict,
    cams: list[ob.Camera],
    photo_resolver,
    *,
    scale_m_per_mesh_unit: float,
    max_photos: int,
    registration_ceiling: int,
    coverage_photos: int,
    crop: float,
    depth_m: float,
    max_residual_px: float,
    max_rotation_deg: float,
    max_scale_error: float,
) -> tuple[np.ndarray, float, list[str], dict]:
    normal = registration.orient_normal(
        np.asarray(plane["normale"], float), pf.corners.mean(0), cams,
    )
    horizontal_flipped = registration.orient_frame_for_front_view(pf, normal)
    reference_rgba, reference_mask, depth = registration.render_oc_reference(
        textured_mesh, pf, normal, depth_m, scale_m_per_mesh_unit,
    )
    reference = reference_rgba[..., :3]
    planar_reference = reference_mask & np.isfinite(depth) & (np.abs(depth) <= 0.35)

    can_register = int(planar_reference.sum()) >= 8_000
    if can_register:
        sift = cv2.SIFT_create(nfeatures=5000, contrastThreshold=0.025, edgeThreshold=12)
        reference_points, reference_descriptors = sift.detectAndCompute(
            registration._normalized_gray(reference),
            planar_reference.astype(np.uint8) * 255,
        )
    else:
        reference_points, reference_descriptors = [], None
    ranked = registration.rank_candidates(pf, normal, cams, crop=crop)
    camera_by_key = {str(int(cam.key)): cam for cam in cams}
    rank_by_key = {str(candidate["key"]): rank for rank, candidate in enumerate(ranked, 1)}

    registered_images: list[np.ndarray] = []
    registered_planar_masks: list[np.ndarray] = []
    accepted_full_masks: list[np.ndarray] = []
    accepted_keys: list[str] = []
    attempted_keys: set[str] = set()
    photo_reports: list[dict[str, object]] = []

    if can_register:
        selection_target = min(max_photos, registration_ceiling)
        selection_rounds: list[dict[str, object]] = []
        selection_report: dict[str, object] = {}
        global_report: dict[str, object] = {}
        corrections: list[dict[str, object]] = []
        accepted_images: list[np.ndarray] = []
        accepted_planar_masks: list[np.ndarray] = []

        while selection_target > 0:
            registration_candidates, round_report = _select_registration_candidates(
                pf, normal, cams, ranked, crop=crop,
                base_photos=selection_target, max_photos=registration_ceiling,
            )
            new_candidates = [
                candidate for candidate in registration_candidates
                if str(candidate["key"]) not in attempted_keys
            ]
            if not new_candidates:
                selection_report = {
                    **round_report,
                    "hard_ceiling": registration_ceiling,
                    "rounds": selection_rounds,
                    "stop_reason": "nessuna nuova foto candidata",
                }
                break

            for candidate in new_candidates:
                key = str(candidate["key"])
                attempted_keys.add(key)
                rank = rank_by_key.get(key, len(ranked) + 1)
                resolved = photo_resolver(key)
                item: dict[str, object] = {
                    "rank": rank, **candidate, "photo_found": bool(resolved),
                }
                if not resolved:
                    photo_reports.append(item)
                    continue
                posed, posed_mask = registration.warp_photo_to_plane(
                    Path(resolved), camera_by_key[key], pf,
                )
                aligned, aligned_mask, residual = registration.register_residual(
                    reference, planar_reference, reference_points, reference_descriptors,
                    posed, posed_mask,
                    max_rotation_deg=max_rotation_deg,
                    max_scale_error=max_scale_error,
                    max_residual_px=max_residual_px,
                )
                item["registration"] = residual
                photo_reports.append(item)
                if bool(residual.get("accepted")):
                    registered_images.append(aligned)
                    registered_planar_masks.append(aligned_mask & planar_reference)
                    accepted_full_masks.append(aligned_mask)
                    accepted_keys.append(key)

            accepted_images, accepted_planar_masks, global_report, corrections = \
                registration.global_align_photos(
                    registered_images, registered_planar_masks, accepted_keys,
                )
            dominant_keys = _dominant_component_keys(global_report, accepted_keys)
            dominant_indices = [
                index for index, key in enumerate(accepted_keys)
                if key in dominant_keys
            ]
            polygon = ob._polygon_mask(pf.tex_w, pf.tex_h, pf.polygon_uv)
            coverage_count = np.zeros((pf.tex_h, pf.tex_w), np.uint16)
            for index in dominant_indices:
                mask = accepted_full_masks[index]
                coverage_count += mask.astype(np.uint16)
            single_coverage = (
                float((coverage_count[polygon] >= 1).mean()) if polygon.any() else 0.0
            )
            double_coverage = (
                float((coverage_count[polygon] >= 2).mean()) if polygon.any() else 0.0
            )
            connected = _alignment_is_connected(global_report, len(accepted_keys))
            dominant_ratio = len(dominant_keys) / max(len(accepted_keys), 1)
            selection_rounds.append({
                "target": selection_target,
                "attempted": len(attempted_keys),
                "accepted": len(accepted_keys),
                "connected": connected,
                "components": len(global_report.get("components", [])) or None,
                "dominant_component": len(dominant_keys),
                "dominant_ratio": round(dominant_ratio, 4),
                "single_coverage": round(single_coverage, 4),
                "double_coverage": round(double_coverage, 4),
            })
            selection_report = {
                **round_report,
                "hard_ceiling": registration_ceiling,
                "rounds": selection_rounds,
            }
            if (len(dominant_keys) >= 2 and dominant_ratio >= 0.70
                    and single_coverage >= 0.80 and double_coverage >= 0.70):
                selection_report["stop_reason"] = \
                    "copertura e componente dominante sufficienti"
                break
            if len(attempted_keys) >= min(registration_ceiling, len(ranked)):
                selection_report["stop_reason"] = "raggiunto il tetto tecnico"
                break
            next_target = min(
                registration_ceiling,
                max(selection_target + 8, int(math.ceil(selection_target * 1.5))),
            )
            if next_target <= selection_target:
                selection_report["stop_reason"] = "raggiunto il tetto tecnico"
                break
            selection_target = next_target

        dominant_keys = _dominant_component_keys(global_report, accepted_keys)
        if dominant_keys and len(dominant_keys) < len(accepted_keys):
            discarded_keys = [key for key in accepted_keys if key not in dominant_keys]
            keep = [index for index, key in enumerate(accepted_keys) if key in dominant_keys]
            accepted_images = [accepted_images[index] for index in keep]
            accepted_planar_masks = [accepted_planar_masks[index] for index in keep]
            accepted_full_masks = [accepted_full_masks[index] for index in keep]
            corrections = [corrections[index] for index in keep]
            accepted_keys = [accepted_keys[index] for index in keep]
            selection_report["discarded_disconnected"] = discarded_keys
            for item in photo_reports:
                if str(item.get("key")) in discarded_keys:
                    item["registration"]["excluded_disconnected"] = True
    else:
        accepted_images = []
        accepted_planar_masks = []
        global_report = {}
        corrections = []
        selection_report = {
            "budget": 0, "selected": 0, "reason": "riferimento planare insufficiente",
        }

    anchor_key = _stable_mosaic_anchor(accepted_keys, ranked)
    if anchor_key is not None:
        anchor_index = accepted_keys.index(anchor_key)
        if anchor_index != 0:
            order = [anchor_index, *(
                index for index in range(len(accepted_keys)) if index != anchor_index
            )]
            accepted_images = [accepted_images[index] for index in order]
            accepted_planar_masks = [accepted_planar_masks[index] for index in order]
            accepted_full_masks = [accepted_full_masks[index] for index in order]
            corrections = [corrections[index] for index in order]
            accepted_keys = [accepted_keys[index] for index in order]

    size = (pf.tex_w, pf.tex_h)
    compositing_masks = [
        cv2.warpAffine(
            mask.astype(np.uint8), np.asarray(correction["matrix"], np.float64),
            size, flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT,
        ) > 0
        for mask, correction in zip(accepted_full_masks, corrections)
    ]
    accepted_images, accepted_planar_masks, compositing_masks, seam_refinements = \
        _refine_major_seams(
            accepted_images, accepted_planar_masks, compositing_masks,
            accepted_keys,
        )
    for key, correction in zip(accepted_keys, corrections):
        for item in photo_reports:
            if str(item.get("key")) == key and isinstance(item.get("registration"), dict):
                item["registration"]["global_correction"] = correction
                break

    covered = np.zeros((pf.tex_h, pf.tex_w), bool)
    for mask in compositing_masks:
        covered |= mask

    # Se il riferimento OC non ha feature sufficienti, conserva comunque il
    # risultato metrico delle pose invece di produrre una texture vuota.
    filler_limit = max(max_photos, coverage_photos)
    for rank, candidate in _pose_filler_candidates(
        ranked, attempted_keys, set(accepted_keys), filler_limit,
    ):
        key = str(candidate["key"])
        cam = camera_by_key[key]
        predicted_mask = registration.photo_coverage_mask(cam, pf)
        new_pixels = predicted_mask & ~covered
        if int(new_pixels.sum()) < 200:
            continue
        resolved = photo_resolver(key)
        if not resolved:
            continue
        posed, posed_mask = registration.warp_photo_to_plane(Path(resolved), cam, pf)
        # I filler non hanno superato la registrazione visuale: possono chiudere
        # un buco, ma non devono mai competere con fotografie gia allineate.
        # Usare la maschera completa qui reintroduceva cuciture su finestre e
        # cornici, soprattutto nella fascia alta della facciata.
        filler_mask = posed_mask & ~covered
        if int(filler_mask.sum()) < 200:
            continue
        accepted_images.append(posed)
        compositing_masks.append(filler_mask)
        accepted_keys.append(key)
        filler_report = {
            "rank": rank, **candidate, "photo_found": True,
            "registration": {
                "accepted": True,
                "reason": "riempimento soli pixel scoperti da posa",
                "pose_only_filler": True,
                "gap_only": True,
                "coverage_pixels": int(filler_mask.sum()),
                "global_correction": _identity_correction(),
            },
        }
        existing = next(
            (report for report in photo_reports if str(report.get("key")) == key),
            None,
        )
        if existing is None:
            photo_reports.append(filler_report)
        else:
            existing.update(filler_report)
        covered |= filler_mask

    rgba = coverage_rgba(mosaic(accepted_images, compositing_masks, reference),
                         compositing_masks)
    polygon = ob._polygon_mask(pf.tex_w, pf.tex_h, pf.polygon_uv)
    coverage = float(covered[polygon].mean()) if polygon.any() else 0.0
    report = {
        "horizontal_flipped_for_front_view": horizontal_flipped,
        "oc_reference_coverage": round(float(reference_mask[polygon].mean()), 4)
        if polygon.any() else 0.0,
        "planar_reference_coverage": round(float(planar_reference[polygon].mean()), 4)
        if polygon.any() else 0.0,
        "accepted_photos": len(accepted_images),
        "registered_photos": len(corrections),
        "mosaic_anchor_key": anchor_key,
        "seam_refinements": seam_refinements,
        "registration_selection": selection_report,
        "global_alignment": global_report,
        "photos": photo_reports,
    }
    return rgba, coverage, accepted_keys, report


def bake_planes(
    clean_mesh_path: str,
    raw_obj_path: str,
    raw_mtl_path: str,
    poses: dict,
    photos_dir: str,
    planes_doc: dict,
    out_dir: str,
    *,
    texel_mm: float = 20.0,
    max_photos: int = 20,
    registration_ceiling: int = 80,
    coverage_photos: int = 100,
    crop: float = 0.9,
    scale_m_per_mesh_unit: float = 1.0,
    photo_resolver=None,
    progress=None,
    log=print,
) -> dict:
    """Bake sequenziale di tutti i piani con riferimento OC testurizzato."""
    if photo_resolver is None:
        photo_resolver = lambda key: ob.photo_path(photos_dir, key)
    os.makedirs(out_dir, exist_ok=True)
    vertices, faces = ob.load_obj(clean_mesh_path)
    cams = ob.load_cameras(poses)
    textured_mesh = registration.load_textured_obj(
        Path(raw_obj_path), Path(raw_mtl_path),
    )
    pb = planes_doc.get("piano_base") or {}
    up_world = ob._unit(np.asarray(pb.get("up", [0.0, 1.0, 0.0]), float))
    texel_m = texel_mm / 1000.0
    planes = planes_doc.get("planes", [])
    frames: list[tuple[int, str, str, ob.PlaneFrame]] = []
    results: list[dict] = []
    reports: list[dict] = []
    total_area = 0.0
    lines = [f"Superfici piani - bake OC reference {texel_mm:.0f} mm/texel", ""]

    for index, plane in enumerate(planes, 1):
        name = plane.get("nome") or plane.get("tipo") or f"piano{index}"
        pf = ob.plane_frame(
            plane, up_world, vertices, faces, texel_m,
            scale_m_per_mesh_unit=scale_m_per_mesh_unit,
        )
        if pf is None:
            log(f"  piano {index} ({name}): degenere, salto")
            continue
        rgba, coverage, used, report = _compose_plane(
            textured_mesh, pf, plane, cams, photo_resolver,
            scale_m_per_mesh_unit=scale_m_per_mesh_unit,
            max_photos=max_photos,
            registration_ceiling=registration_ceiling,
            coverage_photos=coverage_photos,
            crop=crop,
            depth_m=2.0,
            max_residual_px=40.0,
            max_rotation_deg=0.5,
            max_scale_error=0.03,
        )
        filename = f"plane_{index}_{ob._sanitize(name)}.png"
        # Tutta la pipeline OpenCV mantiene BGR/BGRA. Un ulteriore RGBA→BGRA
        # scambiava rosso e blu e produceva la dominante azzurra nei PNG.
        _write_texture_png(os.path.join(out_dir, filename), rgba)
        area = pf.area_m2
        total_area += area
        result = {
            "index": index, "nome": name, "file": filename,
            "width_m": round(pf.width_m, 3), "height_m": round(pf.height_m, 3),
            "tex_w": pf.tex_w, "tex_h": pf.tex_h,
            "area_m2": round(area, 2), "coverage": round(coverage, 3),
            "photos_used": len(used), "registered_photos": report["registered_photos"],
            "registration_budget": report["registration_selection"].get("budget", 0),
            "projection_mode": "oc_reference_registered",
        }
        results.append(result)
        reports.append({"index": index, "nome": name, **report})
        frames.append((index, name, filename, pf))
        lines.append(
            f"plane_{index}_{name:<16.16s} {pf.width_m:6.2f} x {pf.height_m:6.2f} m "
            f"{area:8.2f} m2   copertura {coverage * 100:3.0f}%",
        )
        log(
            f"  piano {index} ({name}): {pf.tex_w}x{pf.tex_h}px, "
            f"{len(used)} foto, copertura {coverage * 100:.0f}%",
        )
        if progress:
            progress(index, len(planes), name)
        gc.collect()

    lines += ["", f"TOTALE {total_area:8.2f} m2"]
    Path(out_dir, "_superfici.txt").write_text("\n".join(lines) + "\n")
    Path(out_dir, "_registration.json").write_text(
        json.dumps({"schema": "acro.oc-reference-registration/v1", "planes": reports},
                   indent=2, ensure_ascii=False),
    )
    main_obj, _ = ob._write_textured_mesh(out_dir, frames)
    coverage = (
        sum(item["coverage"] * item["area_m2"] for item in results) / total_area
        if total_area > 0 else 0.0
    )
    return {
        "planes": results,
        "total_area_m2": round(total_area, 2),
        "coverage": round(coverage, 3),
        "main_obj": main_obj,
        "out_dir": out_dir,
        "count": len(results),
        "projection_mode": "oc_reference_registered",
        "texture_encoding": "sRGB",
    }
