"""Segmentazione locale e spiegabile degli elementi di una facciata rettificata.

Il rilevatore non dipende da etichette testuali. Combina superpixel SLIC in
CIELAB, compensazione dell'illuminazione, contrasto locale e regolarita della
facciata. L'output e una proposta revisionabile, non una classificazione finale.
"""
from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np


_PALETTE = np.asarray([
    (55, 126, 184), (228, 26, 28), (77, 175, 74), (152, 78, 163),
    (255, 127, 0), (255, 255, 51), (166, 86, 40), (247, 129, 191),
    (153, 153, 153), (0, 191, 196), (127, 63, 152), (191, 191, 0),
    (36, 90, 160), (220, 80, 90), (55, 160, 120), (200, 120, 40),
], dtype=np.uint8)


@dataclass(frozen=True)
class WorkingImage:
    bgr: np.ndarray
    scale: float
    valid: np.ndarray
    face_bounds: tuple[tuple[int, int, int, int], ...]


def _load_manifest(path: Path | None) -> dict:
    if path is None or not path.exists():
        return {}
    return json.loads(path.read_text())


def _working_image(image: np.ndarray, manifest: dict, max_width: int) -> WorkingImage:
    height, width = image.shape[:2]
    scale = min(1.0, float(max_width) / max(width, 1))
    if scale < 1.0:
        size = (max(1, round(width * scale)), max(1, round(height * scale)))
        bgr = cv2.resize(image, size, interpolation=cv2.INTER_AREA)
    else:
        bgr = image.copy()

    valid = np.zeros(bgr.shape[:2], np.uint8)
    face_bounds = []
    faces = manifest.get("faces") or []
    if faces:
        for face in faces:
            x0 = max(0, round(float(face.get("x", 0)) * scale))
            y0 = max(0, round(float(face.get("y", 0)) * scale))
            x1 = min(bgr.shape[1], round((float(face.get("x", 0)) +
                                         float(face.get("width", 0))) * scale))
            y1 = min(bgr.shape[0], round((float(face.get("y", 0)) +
                                         float(face.get("height", 0))) * scale))
            if x1 > x0 and y1 > y0:
                valid[y0:y1, x0:x1] = 255
                face_bounds.append((x0, y0, x1, y1))
    else:
        valid.fill(255)
        face_bounds.append((0, 0, bgr.shape[1], bgr.shape[0]))
    return WorkingImage(
        bgr=bgr, scale=scale, valid=valid, face_bounds=tuple(face_bounds))


def _normalized_lab(bgr: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Restituisce Lab per colore e L compensata per ombre lente."""
    blurred = cv2.GaussianBlur(bgr, (3, 3), 0)
    lab = cv2.cvtColor(blurred, cv2.COLOR_BGR2LAB).astype(np.float32)
    lightness = lab[:, :, 0]
    sigma = max(min(bgr.shape[:2]) / 18.0, 18.0)
    illumination = cv2.GaussianBlur(lightness, (0, 0), sigmaX=sigma, sigmaY=sigma)
    reference = float(np.median(illumination))
    normalized_l = np.clip(lightness - illumination + reference, 0, 255)
    normalized = lab.copy()
    normalized[:, :, 0] = normalized_l
    return lab, normalized


def _superpixel_features(
    bgr: np.ndarray, valid: np.ndarray, region_size: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    lab, normalized = _normalized_lab(bgr)
    slic_input = np.clip(normalized, 0, 255).astype(np.uint8)
    slic = cv2.ximgproc.createSuperpixelSLIC(
        slic_input, algorithm=cv2.ximgproc.SLICO,
        region_size=max(int(region_size), 6), ruler=10.0,
    )
    slic.iterate(8)
    slic.enforceLabelConnectivity(20)
    labels = slic.getLabels().astype(np.int32)
    count = int(labels.max()) + 1

    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    gradient = cv2.magnitude(gx, gy)
    gradient = np.clip(gradient / 96.0, 0.0, 1.0)

    flat_labels = labels.ravel()
    weights = (valid.ravel() > 0).astype(np.float32)
    sizes = np.bincount(flat_labels, weights=weights, minlength=count)
    safe = np.maximum(sizes, 1.0)
    channels = [normalized[:, :, i] for i in range(3)]
    means = [
        np.bincount(flat_labels, weights=channel.ravel() * weights,
                    minlength=count) / safe
        for channel in channels
    ]
    mean_l2 = np.bincount(
        flat_labels, weights=(channels[0].ravel() ** 2) * weights,
        minlength=count,
    ) / safe
    std_l = np.sqrt(np.maximum(mean_l2 - means[0] ** 2, 0.0))
    edge = np.bincount(
        flat_labels, weights=gradient.ravel() * weights, minlength=count,
    ) / safe
    raw_l = np.bincount(
        flat_labels, weights=lab[:, :, 0].ravel() * weights, minlength=count,
    ) / safe
    features = np.column_stack((means[0], means[1], means[2], std_l, edge))
    descriptors = np.column_stack((raw_l, means[1], means[2], std_l, edge, sizes))
    usable = sizes > 0
    return labels, features[usable], descriptors[usable]


def _cluster_superpixels(
    labels: np.ndarray, features: np.ndarray, valid: np.ndarray, clusters: int,
) -> tuple[np.ndarray, np.ndarray]:
    count = int(labels.max()) + 1
    usable_labels = np.unique(labels[valid > 0])
    clusters = min(max(int(clusters), 2), len(usable_labels))
    center = np.median(features, axis=0)
    spread = np.median(np.abs(features - center), axis=0)
    spread = np.maximum(spread, np.asarray([8.0, 4.0, 4.0, 2.0, 0.06]))
    standardized = (features - center) / spread
    standardized *= np.asarray([1.25, 1.15, 1.15, 0.75, 0.85])
    cv2.setRNGSeed(4317)
    _, assignments, centers = cv2.kmeans(
        standardized.astype(np.float32), clusters, None,
        (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 80, 0.02),
        8, cv2.KMEANS_PP_CENTERS,
    )
    lookup = np.full(count, -1, np.int32)
    lookup[usable_labels] = assignments.ravel()
    material_map = lookup[labels]
    material_map[valid == 0] = -1
    return material_map, centers


def _material_preview(material_map: np.ndarray, bgr: np.ndarray) -> np.ndarray:
    preview = np.zeros_like(bgr)
    for cluster in range(int(material_map.max()) + 1):
        preview[material_map == cluster] = _PALETTE[cluster % len(_PALETTE)][::-1]
    contours = np.zeros(material_map.shape, np.uint8)
    contours[1:, :] |= material_map[1:, :] != material_map[:-1, :]
    contours[:, 1:] |= material_map[:, 1:] != material_map[:, :-1]
    preview[contours > 0] = (18, 18, 18)
    return preview


def _box_overlap_on_smaller(a: list[int], b: list[int]) -> float:
    x0, y0 = max(a[0], b[0]), max(a[1], b[1])
    x1, y1 = min(a[2], b[2]), min(a[3], b[3])
    intersection = max(x1 - x0, 0) * max(y1 - y0, 0)
    smaller = min((a[2] - a[0]) * (a[3] - a[1]),
                  (b[2] - b[0]) * (b[3] - b[1]))
    return intersection / max(smaller, 1)


def _candidate_face_bounds(valid: np.ndarray) -> list[tuple[int, int, int, int]]:
    components, labels, stats, _ = cv2.connectedComponentsWithStats(
        (valid > 0).astype(np.uint8), 8)
    bounds = []
    for label in range(1, components):
        x, y, width, height, area = stats[label]
        if area >= valid.size * 0.002:
            bounds.append((x, y, x + width, y + height))
    return bounds or [(0, 0, valid.shape[1], valid.shape[0])]


def _rectangular_opening_candidates(
    bgr: np.ndarray, valid: np.ndarray,
    face_bounds: list[tuple[int, int, int, int]] | tuple[tuple[int, int, int, int], ...] | None = None,
) -> list[dict]:
    """Trova aperture come rettangoli ripetuti, senza dipendere da una classe AI."""
    gray_full = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    proposals = []
    for face_index, (face_x0, face_y0, face_x1, face_y1) in enumerate(
            face_bounds or _candidate_face_bounds(valid)):
        gray = gray_full[face_y0:face_y1, face_x0:face_x1]
        if min(gray.shape) < 30:
            continue
        edges = cv2.Canny(gray, 48, 138)
        unit = max(round(min(gray.shape) / 420), 1)
        edges = cv2.morphologyEx(
            edges, cv2.MORPH_CLOSE,
            cv2.getStructuringElement(cv2.MORPH_RECT, (unit * 2 + 1, unit * 4 + 1)),
        )
        contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        face_area = float(gray.size)
        minimum_width = max(14, round(bgr.shape[1] * 0.010))
        minimum_height = max(32, round(bgr.shape[0] * 0.043))
        for contour in contours:
            x, y, width, height = cv2.boundingRect(contour)
            area_fraction = width * height / face_area
            aspect = width / max(height, 1)
            if (width < minimum_width or height < minimum_height or
                    not (0.0007 <= area_fraction <= 0.055 and 0.26 <= aspect <= 1.35)):
                continue
            fill = float(cv2.contourArea(contour)) / max(width * height, 1)
            if fill < 0.34:
                continue
            margin = max(round(min(width, height) * 0.18), 3)
            inner = gray[y:y + height, x:x + width]
            ax0, ay0 = max(x - margin, 0), max(y - margin, 0)
            ax1, ay1 = min(x + width + margin, gray.shape[1]), min(y + height + margin, gray.shape[0])
            surround = gray[ay0:ay1, ax0:ax1].copy()
            surround[max(y - ay0, 0):min(y - ay0 + height, surround.shape[0]),
                     max(x - ax0, 0):min(x - ax0 + width, surround.shape[1])] = 0
            surround_values = surround[surround > 0]
            contrast = (abs(float(np.median(surround_values)) - float(np.median(inner))) / 64.0
                        if surround_values.size else 0.0)
            quality = min(1.0, fill * 0.72 + min(contrast, 1.0) * 0.28)
            global_box = [face_x0 + x, face_y0 + y,
                          face_x0 + x + width, face_y0 + y + height]
            proposals.append({
                "box": global_box,
                "center": (face_x0 + x + width * 0.5,
                           face_y0 + y + height * 0.5),
                "width": width,
                "height": height,
                "fill": fill,
                "quality": quality,
                "face_index": face_index,
            })

    # Elimina i rettangoli annidati prodotti da telaio, vetro e tapparella.
    deduplicated = []
    for proposal in sorted(
            proposals, key=lambda item: item["quality"] * math.sqrt(
                item["width"] * item["height"]), reverse=True):
        if all(_box_overlap_on_smaller(proposal["box"], item["box"]) < 0.72
               for item in deduplicated):
            deduplicated.append(proposal)

    # La regolarita vale anche tra facce adiacenti, che condividono la stessa scala.
    for candidate in deduplicated:
        repeats = 0
        aligned_repeats = 0
        cx, cy = candidate["center"]
        for other in deduplicated:
            if other is candidate:
                continue
            width_ratio = other["width"] / candidate["width"]
            height_ratio = other["height"] / candidate["height"]
            similar = 0.68 <= width_ratio <= 1.47 and 0.68 <= height_ratio <= 1.47
            if not similar:
                continue
            repeats += 1
            row_aligned = abs(other["center"][1] - cy) <= max(
                candidate["height"], other["height"]) * 0.24
            column_aligned = abs(other["center"][0] - cx) <= max(
                candidate["width"], other["width"]) * 0.30
            separated = _box_overlap_on_smaller(candidate["box"], other["box"]) < 0.20
            if separated and (row_aligned or column_aligned):
                aligned_repeats += 1

        score = 0.20 + candidate["quality"] * 0.34
        reasons = ["contorno_rettangolare"]
        if repeats:
            score += min(repeats, 4) * 0.055
            reasons.append("dimensione_ripetuta")
        if aligned_repeats:
            score += min(aligned_repeats, 4) * 0.085
            reasons.append("allineamento_architettonico")
        candidate["score"] = min(score, 0.99)
        candidate["repeats"] = repeats
        candidate["aligned_repeats"] = aligned_repeats
        candidate["reason"] = reasons

    return [
        item for item in deduplicated
        if item["score"] >= 0.62 and (
            item["aligned_repeats"] >= 2 or
            (item["quality"] >= 0.82 and
             item["height"] >= bgr.shape[0] * 0.075)
        )
    ]


def _row_groups(candidates: list[dict]) -> list[list[dict]]:
    rows: list[list[dict]] = []
    for candidate in sorted(candidates, key=lambda item: item["center"][1]):
        for row in rows:
            center = float(np.median([item["center"][1] for item in row]))
            height = float(np.median([item["height"] for item in row]))
            if abs(candidate["center"][1] - center) <= max(
                    height, candidate["height"]) * 0.30:
                row.append(candidate)
                break
        else:
            rows.append([candidate])
    return rows


def _row_coherence(row: list[dict]) -> float:
    if len(row) < 3:
        return 0.0
    widths = np.asarray([item["width"] for item in row], np.float32)
    heights = np.asarray([item["height"] for item in row], np.float32)
    dispersion = widths.std() / max(widths.mean(), 1.0) + \
        heights.std() / max(heights.mean(), 1.0)
    return float(len(row) * math.exp(-4.0 * dispersion) *
                 math.sqrt(float(np.median(widths) * np.median(heights))))


def _grid_columns(row: list[dict], face_x0: int, face_width: int) -> list[float]:
    centers = sorted(float(item["center"][0] - face_x0) for item in row)
    if len(centers) < 3:
        return []
    gaps = np.diff(centers)
    median_gap = float(np.median(gaps))
    ordinary = gaps[gaps <= median_gap * 1.65]
    spacing = float(np.median(ordinary)) if ordinary.size else median_gap
    if spacing <= 1.0:
        return []

    # Riempie i salti da due campate e completa una campata al margine quando
    # la distanza dal bordo e compatibile con la stessa griglia.
    columns = [centers[0]]
    for center in centers[1:]:
        steps = max(1, int(round((center - columns[-1]) / spacing)))
        for _ in range(steps):
            columns.append(columns[-1] + spacing)
    half_width = float(np.median([item["width"] for item in row])) * 0.5
    while columns[0] - spacing - half_width >= 0:
        columns.insert(0, columns[0] - spacing)
    while columns[-1] + spacing + half_width <= face_width:
        columns.append(columns[-1] + spacing)
    return columns


def _edge_rectangle_score(gray: np.ndarray, width: int, height: int) -> np.ndarray:
    blurred = cv2.GaussianBlur(gray, (3, 3), 0)
    vertical = np.abs(cv2.Sobel(blurred, cv2.CV_32F, 1, 0, ksize=3))
    horizontal = np.abs(cv2.Sobel(blurred, cv2.CV_32F, 0, 1, ksize=3))
    vertical /= max(float(np.percentile(vertical, 95)), 1.0)
    horizontal /= max(float(np.percentile(horizontal, 95)), 1.0)
    vertical = np.clip(vertical, 0.0, 2.0)
    horizontal = np.clip(horizontal, 0.0, 2.0)
    vertical = cv2.boxFilter(
        vertical, -1, (3, max(7, round(height * 0.65))), normalize=True)
    horizontal = cv2.boxFilter(
        horizontal, -1, (max(7, round(width * 0.65)), 3), normalize=True)
    dx, dy = width // 2, height // 2
    score = np.zeros(gray.shape, np.float32)
    if gray.shape[0] <= height or gray.shape[1] <= width:
        return score
    score[dy:-dy, dx:-dx] = (
        vertical[dy:-dy, :-2 * dx] + vertical[dy:-dy, 2 * dx:] +
        horizontal[:-2 * dy, dx:-dx] + horizontal[2 * dy:, dx:-dx]
    ) * 0.25
    return score


def _complete_repeated_grid(
    bgr: np.ndarray,
    face_bounds: tuple[tuple[int, int, int, int], ...],
    direct_candidates: list[dict],
) -> list[dict]:
    """Completa file e colonne solo quando esiste una riga diretta coerente."""
    completed = []
    for face_index, (x0, y0, x1, y1) in enumerate(face_bounds):
        face_candidates = [
            item for item in direct_candidates
            if x0 <= item["center"][0] < x1 and y0 <= item["center"][1] < y1
        ]
        rows = _row_groups(face_candidates)
        if not rows:
            continue
        seed = max(rows, key=_row_coherence)
        if len(seed) < 4 or _row_coherence(seed) < 120.0:
            continue
        width = max(12, round(float(np.median([item["width"] for item in seed]))))
        height = max(24, round(float(np.median([item["height"] for item in seed]))))
        columns = _grid_columns(seed, x0, x1 - x0)
        if len(columns) < 4:
            continue

        gray = cv2.cvtColor(bgr[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY)
        score = _edge_rectangle_score(gray, width, height)
        dx, dy = width // 2, height // 2
        y_values = np.arange(dy, gray.shape[0] - dy)
        if not len(y_values):
            continue
        row_signal = []
        for y in y_values:
            values = [score[y, min(max(round(x), dx), gray.shape[1] - dx - 1)]
                      for x in columns]
            strongest = sorted(values, reverse=True)[:max(3, round(len(values) * 0.70))]
            row_signal.append(float(np.mean(strongest)))
        signal = np.asarray(row_signal, np.float32)
        signal = cv2.GaussianBlur(
            signal[:, None], (1, 0), sigmaX=0,
            sigmaY=max(height / 18.0, 2.0)).ravel()
        maxima = cv2.dilate(
            signal[:, None],
            np.ones((max(3, round(height * 0.84)), 1), np.uint8)).ravel()
        peak_indices = np.flatnonzero(signal == maxima)
        peaks = sorted(
            ((float(signal[index]), int(y_values[index])) for index in peak_indices),
            reverse=True,
        )[:8]
        if not peaks:
            continue
        best_signal = max(peaks[0][0], 1e-6)

        for row_score, center_y in peaks:
            if row_score < best_signal * 0.47:
                continue
            for center_x in columns:
                cx = min(max(round(center_x), dx), gray.shape[1] - dx - 1)
                search_x = max(round(width * 0.10), 2)
                search_y = max(round(height * 0.08), 2)
                sx0, sx1 = max(cx - search_x, dx), min(cx + search_x + 1, gray.shape[1] - dx)
                sy0, sy1 = max(center_y - search_y, dy), min(
                    center_y + search_y + 1, gray.shape[0] - dy)
                local = score[sy0:sy1, sx0:sx1]
                if not local.size:
                    continue
                offset_y, offset_x = np.unravel_index(int(np.argmax(local)), local.shape)
                refined_x, refined_y = sx0 + offset_x, sy0 + offset_y
                local_score = float(score[refined_y, refined_x])
                if local_score < row_score * 0.62:
                    continue
                box = [x0 + refined_x - dx, y0 + refined_y - dy,
                       x0 + refined_x + dx, y0 + refined_y + dy]
                completed.append({
                    "box": box,
                    "center": (x0 + refined_x, y0 + refined_y),
                    "width": width,
                    "height": height,
                    "fill": 1.0,
                    "quality": min(local_score / best_signal, 1.0),
                    "score": min(0.99, 0.62 + 0.30 * local_score / best_signal),
                    "repeats": len(columns) - 1,
                    "aligned_repeats": len(columns) - 1,
                    "reason": ["griglia_architettonica", "quattro_bordi_coerenti"],
                    "source": "structural_grid",
                    "face_index": face_index,
                })
    return completed


def _merge_candidates(direct: list[dict], completed: list[dict]) -> list[dict]:
    merged = []
    # La griglia contiene il vano completo e prevale sui frammenti interni.
    for candidate in completed + direct:
        if all(_box_overlap_on_smaller(candidate["box"], item["box"]) < 0.62
               for item in merged):
            item = dict(candidate)
            item.setdefault("source", "direct_geometry")
            merged.append(item)
    return merged


def _candidate_preview(bgr: np.ndarray, candidates: list[dict]) -> np.ndarray:
    preview = bgr.copy()
    overlay = preview.copy()
    for item in candidates:
        x0, y0, x1, y1 = item["box"]
        cv2.rectangle(overlay, (x0, y0), (x1, y1), (20, 180, 255), -1)
    preview = cv2.addWeighted(overlay, 0.16, preview, 0.84, 0)
    for index, item in enumerate(candidates, 1):
        x0, y0, x1, y1 = item["box"]
        color = ((35, 190, 70) if item.get("source") == "structural_grid"
                 else (15, 125, 255) if item["repeats"] else (0, 205, 220))
        cv2.rectangle(preview, (x0, y0), (x1, y1), color, 2)
        label = f"{index}  {item['score']:.2f}"
        cv2.putText(preview, label, (x0 + 3, max(y0 - 5, 12)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.38, color, 1, cv2.LINE_AA)
    return preview


def _restore_size(image: np.ndarray, shape: tuple[int, int]) -> np.ndarray:
    height, width = shape
    if image.shape[:2] == shape:
        return image
    return cv2.resize(image, (width, height), interpolation=cv2.INTER_NEAREST)


def detect(
    image_path: Path, output: Path, manifest_path: Path | None,
    *, clusters: int = 10, region_size: int = 18, max_width: int = 2400,
) -> dict:
    original = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
    if original is None:
        raise RuntimeError(f"Immagine non leggibile: {image_path}")
    manifest = _load_manifest(manifest_path)
    working = _working_image(original, manifest, max_width=max_width)
    labels, features, _ = _superpixel_features(
        working.bgr, working.valid, region_size=region_size)
    material_map, _ = _cluster_superpixels(
        labels, features, working.valid, clusters=clusters)
    direct_candidates = _rectangular_opening_candidates(
        working.bgr, working.valid, working.face_bounds)
    completed = _complete_repeated_grid(
        working.bgr, working.face_bounds, direct_candidates)
    candidates = _merge_candidates(direct_candidates, completed)

    output.mkdir(parents=True, exist_ok=True)
    material_preview = _material_preview(material_map, working.bgr)
    candidate_preview = _candidate_preview(working.bgr, candidates)
    cv2.imwrite(str(output / "materials.png"),
                _restore_size(material_preview, original.shape[:2]))
    cv2.imwrite(str(output / "candidates.png"),
                _restore_size(candidate_preview, original.shape[:2]))

    inverse_scale = 1.0 / max(working.scale, 1e-9)
    serialized = []
    for index, item in enumerate(candidates, 1):
        box = [round(value * inverse_scale) for value in item["box"]]
        serialized.append({
            "id": index,
            "type": "opening_candidate",
            "box_px": box,
            "polygon_px": [[box[0], box[1]], [box[2], box[1]],
                           [box[2], box[3]], [box[0], box[3]]],
            "confidence": round(float(item["score"]), 4),
            "repetition_count": int(item["repeats"]),
            "reason": item["reason"],
            "source": item.get("source", "direct_geometry"),
        })
    result = {
        "source_image": str(image_path),
        "image_size_px": [original.shape[1], original.shape[0]],
        "working_scale": working.scale,
        "material_clusters": int(clusters),
        "region_size_px_working": int(region_size),
        "materials_image": "materials.png",
        "candidates_image": "candidates.png",
        "candidate_count": len(serialized),
        "candidates": serialized,
        "method": "lab_slic_local_contrast_regularity_v1",
    }
    (output / "elements.json").write_text(json.dumps(result, indent=2))
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--clusters", type=int, default=10)
    parser.add_argument("--region-size", type=int, default=18)
    parser.add_argument("--max-width", type=int, default=2400)
    args = parser.parse_args()
    result = detect(
        args.image, args.out, args.manifest,
        clusters=args.clusters, region_size=args.region_size,
        max_width=args.max_width,
    )
    print(json.dumps({
        "candidate_count": result["candidate_count"],
        "material_clusters": result["material_clusters"],
    }))


if __name__ == "__main__":
    main()
