"""Shared 2D compositing operations for the local OC registration tools."""
from __future__ import annotations

import cv2
import numpy as np


def mosaic(
    images: list[np.ndarray],
    masks: list[np.ndarray],
    fallback: np.ndarray,
    *,
    content_aware_seams: bool = False,
    content_aware_photo_count: int | None = None,
) -> np.ndarray:
    if not images:
        return np.zeros_like(fallback)

    output = np.zeros_like(fallback, dtype=np.float32)
    covered = np.zeros(fallback.shape[:2], bool)
    remaining = list(range(len(images)))
    seam_finder = (
        cv2.detail_GraphCutSeamFinder("COST_COLOR_GRAD", 10_000, 1_000)
        if content_aware_seams else None
    )
    height, width = fallback.shape[:2]
    seam_scale = min(1.0, 385.0 / max(width, height))
    seam_size = (
        max(1, int(round(width * seam_scale))),
        max(1, int(round(height * seam_scale))),
    )
    while remaining:
        contributions = [int((masks[index] & ~covered).sum()) for index in remaining]
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
        image = images[selected].astype(np.float32)
        mask = masks[selected]
        new_pixels = mask & ~covered
        if not covered.any():
            output[new_pixels] = image[new_pixels]
            covered |= mask
            continue

        overlap = mask & covered
        if int(overlap.sum()) >= 1_000:
            color_delta = np.median(
                output[overlap] - image[overlap], axis=0,
            )
            image = np.clip(image + np.clip(color_delta, -18.0, 18.0), 0, 255)

        seam_allowed = (
            content_aware_photo_count is None
            or selected < content_aware_photo_count
        )
        if seam_finder is not None and seam_allowed and int(overlap.sum()) >= 1_000:
            previous = output.copy()
            seam_images = [
                cv2.UMat(cv2.resize(
                    output, seam_size, interpolation=cv2.INTER_AREA,
                )),
                cv2.UMat(cv2.resize(
                    image, seam_size, interpolation=cv2.INTER_AREA,
                )),
            ]
            seam_masks = [
                cv2.UMat(cv2.resize(
                    covered.astype(np.uint8), seam_size,
                    interpolation=cv2.INTER_NEAREST,
                ) * 255),
                cv2.UMat(cv2.resize(
                    mask.astype(np.uint8), seam_size,
                    interpolation=cv2.INTER_NEAREST,
                ) * 255),
            ]
            seam_finder.find(
                seam_images, [(0, 0), (0, 0)], seam_masks,
            )
            keep_previous = cv2.resize(
                seam_masks[0].get(), (width, height),
                interpolation=cv2.INTER_NEAREST,
            ) > 0
            keep_source = cv2.resize(
                seam_masks[1].get(), (width, height),
                interpolation=cv2.INTER_NEAREST,
            ) > 0
            source_region = keep_source | new_pixels
            output[source_region] = image[source_region]

            # Feather only four pixels around the content-aware partition. The
            # source remains sharp everywhere else, including window frames.
            distance_to_source = cv2.distanceTransform(
                (~source_region).astype(np.uint8), cv2.DIST_L2, 3,
            )
            distance_to_previous = cv2.distanceTransform(
                (~keep_previous).astype(np.uint8), cv2.DIST_L2, 3,
            )
            transition = (
                overlap
                & (distance_to_source <= 4.0)
                & (distance_to_previous <= 4.0)
            )
            denominator = (
                distance_to_source[transition]
                + distance_to_previous[transition]
            )
            alpha = distance_to_previous[transition] / np.maximum(
                denominator, 1e-6,
            )
            output[transition] = (
                previous[transition] * (1.0 - alpha[:, None])
                + image[transition] * alpha[:, None]
            )
            covered |= mask
            continue

        # Keep one source per region. Blend only a narrow strip where a new
        # coverage patch meets the existing mosaic.
        distance_inside = cv2.distanceTransform(covered.astype(np.uint8), cv2.DIST_L2, 3)
        transition = overlap & (distance_inside <= 10.0)
        alpha = np.clip((10.0 - distance_inside[transition]) / 10.0, 0.0, 1.0)
        output[transition] = (
            output[transition] * (1.0 - alpha[:, None])
            + image[transition] * alpha[:, None]
        )
        output[new_pixels] = image[new_pixels]
        covered |= mask
    return np.clip(output, 0, 255).astype(np.uint8)


def best_view(
    images: list[np.ndarray],
    masks: list[np.ndarray],
    fallback: np.ndarray,
) -> np.ndarray:
    output = np.zeros_like(fallback)
    best = np.zeros(fallback.shape[:2], np.float32)
    for rank, (image, mask) in enumerate(zip(images, masks)):
        interior = cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 3)
        score = interior + mask.astype(np.float32) * max(0.0, 1.0 - rank * 0.04)
        selected = score > best
        output[selected] = image[selected]
        best[selected] = score[selected]
    return output


def coverage_rgba(image: np.ndarray, masks: list[np.ndarray]) -> np.ndarray:
    covered = np.zeros(image.shape[:2], bool)
    for mask in masks:
        covered |= mask
    output = cv2.cvtColor(image, cv2.COLOR_BGR2BGRA)
    output[~covered, :3] = 0
    output[..., 3] = covered.astype(np.uint8) * 255
    return output
