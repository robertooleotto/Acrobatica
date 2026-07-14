"""Shared 2D compositing operations for the local OC registration tools."""
from __future__ import annotations

import cv2
import numpy as np


def mosaic(
    images: list[np.ndarray],
    masks: list[np.ndarray],
    fallback: np.ndarray,
) -> np.ndarray:
    if not images:
        return np.zeros_like(fallback)

    output = np.zeros_like(fallback, dtype=np.float32)
    covered = np.zeros(fallback.shape[:2], bool)
    remaining = list(range(len(images)))
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
