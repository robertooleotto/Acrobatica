#!/usr/bin/env python3
"""Apply manual per-photo residual corrections without repeating registration."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np

from scripts.oc_compositing import best_view, coverage_rgba, mosaic


def _manual_transform(
    image: np.ndarray,
    mask: np.ndarray,
    correction: dict,
) -> tuple[np.ndarray, np.ndarray]:
    height, width = image.shape[:2]
    center = ((width - 1) * 0.5, (height - 1) * 0.5)
    # SwiftUI's positive screen rotation is clockwise; OpenCV's is counter-clockwise.
    matrix = cv2.getRotationMatrix2D(
        center,
        -float(correction.get("rotation_deg", 0.0)),
        float(correction.get("scale", 1.0)),
    )
    matrix[0, 2] += float(correction.get("offset_x", 0.0))
    matrix[1, 2] += float(correction.get("offset_y", 0.0))
    size = (width, height)
    adjusted = cv2.warpAffine(
        image, matrix, size, flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
    )
    adjusted_mask = cv2.warpAffine(
        mask.astype(np.uint8), matrix, size, flags=cv2.INTER_NEAREST,
        borderMode=cv2.BORDER_CONSTANT,
    ) > 0
    return adjusted, adjusted_mask


def recompose(output: Path) -> dict[str, object]:
    report = json.loads((output / "report.json").read_text())
    adjustments = json.loads((output / "compositing_adjustments.json").read_text())
    if adjustments.get("plane_id") != report.get("plane_id"):
        raise RuntimeError("Le correzioni appartengono a un altro piano")
    if adjustments.get("output_size_px") != report.get("size_px"):
        raise RuntimeError("Le correzioni appartengono a un'altra risoluzione")
    manual_by_photo = {
        str(item["photo_id"]): item.get("manual", {})
        for item in adjustments.get("photos", [])
    }

    reference_rgba = cv2.imread(str(output / "01_oc_reference.png"), cv2.IMREAD_UNCHANGED)
    planar = cv2.imread(str(output / "02b_planar_mask.png"), cv2.IMREAD_GRAYSCALE)
    if reference_rgba is None or planar is None:
        raise RuntimeError("Riferimento OC o maschera planare assenti")
    reference = reference_rgba[..., :3]
    planar_mask = planar > 0
    coverage_target = planar_mask if planar_mask.any() else reference_rgba[..., 3] > 0

    images: list[np.ndarray] = []
    masks: list[np.ndarray] = []
    applied: list[str] = []
    for photo in report.get("photos", []):
        registration = photo.get("registration") or {}
        if not registration.get("accepted"):
            continue
        key = str(photo["key"])
        correction = manual_by_photo.get(key, {"enabled": True})
        if not bool(correction.get("enabled", True)):
            continue
        stem = f"photo_{int(photo['rank']):02d}_{int(key):04d}"
        image = cv2.imread(str(output / f"{stem}_aligned.png"), cv2.IMREAD_COLOR)
        mask = cv2.imread(str(output / f"{stem}_aligned_mask.png"), cv2.IMREAD_GRAYSCALE)
        if image is None or mask is None:
            continue
        image, adjusted_mask = _manual_transform(image, mask > 0, correction)
        images.append(image)
        masks.append(adjusted_mask)
        applied.append(key)

    blend = mosaic(images, masks, reference)
    best = best_view(images, masks, reference)
    cv2.imwrite(str(output / "03_registered_mosaic_blend.png"), coverage_rgba(blend, masks))
    cv2.imwrite(str(output / "04_registered_best_view.png"), coverage_rgba(best, masks))

    union = np.zeros(planar_mask.shape, bool)
    for mask in masks:
        union |= mask
    summary = {
        "schema": "acro.compositing-recompose/v1",
        "plane_id": report.get("plane_id"),
        "photos_applied": applied,
        "registered_planar_coverage": round(
            float(union[coverage_target].mean()) if coverage_target.any() else 0.0,
            4,
        ),
    }
    (output / "compositing_recompose_report.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False)
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(recompose(args.output), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
