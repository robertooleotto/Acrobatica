"""Rilevamento aperture sulle texture ortografiche dei piani.

Grounding DINO propone finestre e porte; SAM2 trasforma ogni box in una maschera.
Il risultato persistito usa UV del piano e resta revisionabile senza rilanciare
l'inferenza. I due modelli sono caricati in sequenza per limitare il picco RAM.
"""
from __future__ import annotations

import gc
import hashlib
import os
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

import cv2
import numpy as np
from PIL import Image

from . import session_store, storage_service


class InputsMissing(RuntimeError):
    pass


class DetectionError(RuntimeError):
    pass


_ACTIVE_JOB_STATES = {"queued", "running"}
_JOB_STALE_SECONDS = 45 * 60
_INFERENCE_LOCK = threading.Lock()
_DETECTOR_MODEL = os.environ.get(
    "ACRO_OPENING_DETECTOR_MODEL", "IDEA-Research/grounding-dino-tiny")
_SEGMENTER_MODEL = os.environ.get(
    "ACRO_OPENING_SEGMENTER_MODEL", "facebook/sam2.1-hiera-tiny")
_PROMPT_LABELS = [[
    "window",
    "door",
    "shop window",
    "balcony door",
    "French window",
    "storefront",
    "glass door",
]]


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _job_is_stale(job: dict, now: datetime | None = None) -> bool:
    if job.get("state") not in _ACTIVE_JOB_STATES:
        return False
    raw = job.get("updated_at")
    if not raw:
        return True
    try:
        updated = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
        if updated.tzinfo is None:
            updated = updated.replace(tzinfo=timezone.utc)
    except ValueError:
        return True
    return ((now or datetime.now(timezone.utc)) - updated).total_seconds() > _JOB_STALE_SECONDS


def _set_job(session_id: str, state: str, progress: float,
             message: str, error: str = "") -> None:
    sess = session_store.get_session(session_id)
    if sess is None:
        return
    result = sess.get("result") or {}
    previous = result.get("opening_detection_job") or {}
    now = _now_iso()
    result["opening_detection_job"] = {
        "state": state,
        "progress": min(max(float(progress), 0.0), 1.0),
        "message": message,
        "error": error,
        "started_at": previous.get("started_at") or now,
        "updated_at": now,
    }
    session_store.update_session(session_id, {"result": result})


def _projection(sess: dict) -> dict:
    projection = (sess.get("result") or {}).get("projection") or {}
    if not projection.get("planes") or not projection.get("files"):
        raise InputsMissing("Prima completa la proiezione delle texture sui piani")
    return projection


def _plane_map(projection: dict) -> dict[int, dict]:
    return {int(item["index"]): item for item in projection.get("planes", [])}


def _file_map(projection: dict) -> dict[str, dict]:
    return {Path(item.get("name", "")).name: item
            for item in projection.get("files", []) if isinstance(item, dict)}


def _polygon_area_uv(points: list[list[float]] | list[tuple[float, float]]) -> float:
    if len(points) < 3:
        return 0.0
    area = 0.0
    for index, point in enumerate(points):
        nxt = points[(index + 1) % len(points)]
        area += float(point[0]) * float(nxt[1]) - float(nxt[0]) * float(point[1])
    return abs(area) * 0.5


def _opening_area_m2(opening: dict, plane: dict) -> float:
    rectangle_area = float(plane.get("width_m", 0.0)) * float(plane.get("height_m", 0.0))
    return _polygon_area_uv(opening.get("polygon_uv") or []) * rectangle_area


def _union_area_m2(openings: list[dict], planes: dict[int, dict]) -> float:
    """Area unione rasterizzata: evita doppio conteggio di aperture sovrapposte."""
    total = 0.0
    by_plane: dict[int, list[dict]] = {}
    for opening in openings:
        if opening.get("excluded", True):
            by_plane.setdefault(int(opening["plane_index"]), []).append(opening)
    for plane_index, selected in by_plane.items():
        plane = planes.get(plane_index)
        if not plane:
            continue
        width = min(max(int(plane.get("tex_w", 1024)), 128), 2048)
        height = min(max(int(plane.get("tex_h", 1024)), 128), 2048)
        mask = np.zeros((height, width), np.uint8)
        for opening in selected:
            points = np.asarray([
                [round(min(max(float(u), 0.0), 1.0) * (width - 1)),
                 round((1.0 - min(max(float(v), 0.0), 1.0)) * (height - 1))]
                for u, v in opening.get("polygon_uv") or []
            ], np.int32)
            if len(points) >= 3:
                cv2.fillPoly(mask, [points], 255)
        rectangle = float(plane.get("width_m", 0.0)) * float(plane.get("height_m", 0.0))
        total += float(np.count_nonzero(mask)) / float(width * height) * rectangle
    return total


def _totals(projection: dict, openings: list[dict]) -> dict:
    planes = _plane_map(projection)
    normalized = []
    for raw in openings:
        item = dict(raw)
        plane = planes.get(int(item.get("plane_index", -1)))
        if not plane:
            continue
        item["area_m2"] = round(_opening_area_m2(item, plane), 3)
        normalized.append(item)
    gross = float(projection.get("total_area_m2", 0.0))
    excluded = min(_union_area_m2(normalized, planes), gross)
    return {
        "openings": normalized,
        "count": len(normalized),
        "gross_area_m2": round(gross, 3),
        "excluded_area_m2": round(excluded, 3),
        "net_area_m2": round(max(gross - excluded, 0.0), 3),
    }


def _public_result(sess: dict) -> dict:
    result = sess.get("result") or {}
    job = result.get("opening_detection_job") or {}
    document = result.get("metric_openings") or {}
    has_document = "openings" in document
    return {
        "state": job.get("state", "complete" if has_document else "idle"),
        "progress": float(job.get("progress", 1.0 if has_document else 0.0)),
        "message": job.get("message", "Aperture pronte" if has_document else "Non avviato"),
        "error": job.get("error", ""),
        "count": int(document.get("count", 0)),
        "openings": document.get("openings", []),
        "gross_area_m2": float(document.get("gross_area_m2", 0.0)),
        "excluded_area_m2": float(document.get("excluded_area_m2", 0.0)),
        "net_area_m2": float(document.get("net_area_m2", 0.0)),
        "detector_model": document.get("detector_model", _DETECTOR_MODEL),
        "segmenter_model": document.get("segmenter_model", _SEGMENTER_MODEL),
    }


def start_detection(session_id: str) -> tuple[dict, bool]:
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")
    _projection(sess)
    job = (sess.get("result") or {}).get("opening_detection_job") or {}
    if job.get("state") in _ACTIVE_JOB_STATES and not _job_is_stale(job):
        return _public_result(sess), False
    _set_job(session_id, "queued", 0.0, "Rilevamento aperture accodato")
    return _public_result(session_store.get_session(session_id) or sess), True


def detection_status(session_id: str) -> Optional[dict]:
    sess = session_store.get_session(session_id)
    if sess is not None:
        job = (sess.get("result") or {}).get("opening_detection_job") or {}
        if _job_is_stale(job):
            _set_job(session_id, "failed", 1.0, "Rilevamento interrotto",
                     "Il server e stato riavviato durante il calcolo; rilancia il rilevamento.")
            sess = session_store.get_session(session_id) or sess
    return _public_result(sess) if sess is not None else None


def save_review(session_id: str, openings: list[dict]) -> dict:
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")
    projection = _projection(sess)
    existing = {
        item.get("id"): item
        for item in ((sess.get("result") or {}).get("metric_openings") or {}).get("openings", [])
    }
    reviewed = []
    for item in openings:
        source = existing.get(item.get("id"))
        if source is None:
            raise DetectionError(f"Apertura non riconosciuta: {item.get('id', '')}")
        # La revisione può cambiare solo il flag di computo; geometria e area
        # restano quelle validate dal rilevamento server-side.
        reviewed.append({**source, "excluded": bool(item.get("excluded", True))})
    document = {
        **_totals(projection, reviewed),
        "detector_model": _DETECTOR_MODEL,
        "segmenter_model": _SEGMENTER_MODEL,
        "updated_at": _now_iso(),
    }
    result = sess.get("result") or {}
    result["metric_openings"] = document
    session_store.update_session(session_id, {"result": result})
    return _public_result(session_store.get_session(session_id) or sess)


def _iou(a: list[float], b: list[float]) -> float:
    x0, y0 = max(a[0], b[0]), max(a[1], b[1])
    x1, y1 = min(a[2], b[2]), min(a[3], b[3])
    intersection = max(x1 - x0, 0.0) * max(y1 - y0, 0.0)
    union = max((a[2] - a[0]) * (a[3] - a[1]), 0.0) + \
        max((b[2] - b[0]) * (b[3] - b[1]), 0.0) - intersection
    return intersection / union if union > 0 else 0.0


def _deduplicate(proposals: list[dict], threshold: float = 0.55) -> list[dict]:
    kept = []
    for proposal in sorted(proposals, key=lambda item: item["score"], reverse=True):
        if all(_iou(proposal["box"], item["box"]) < threshold for item in kept):
            kept.append(proposal)
    return kept


def _opening_type(label: str) -> str:
    normalized = label.lower()
    if "shop" in normalized or "store" in normalized:
        return "shop_window"
    if "door" in normalized:
        return "door"
    if "window" in normalized:
        return "window"
    return "unknown"


def _mask_polygon(
    mask: np.ndarray,
    image_size: tuple[int, int],
    *,
    offset: tuple[int, int] = (0, 0),
    canvas_size: tuple[int, int] | None = None,
) -> list[list[float]]:
    height, width = image_size
    canvas_height, canvas_width = canvas_size or image_size
    binary = (np.asarray(mask).squeeze() > 0).astype(np.uint8) * 255
    if binary.shape != (height, width):
        binary = cv2.resize(binary, (width, height), interpolation=cv2.INTER_NEAREST)
    binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return []
    contour = max(contours, key=cv2.contourArea)
    if cv2.contourArea(contour) < 9:
        return []
    epsilon = max(1.5, cv2.arcLength(contour, True) * 0.008)
    polygon = cv2.approxPolyDP(contour, epsilon, True).reshape(-1, 2)
    if len(polygon) < 3:
        return []
    offset_x, offset_y = offset
    return [[round((float(x) + offset_x) / max(canvas_width - 1, 1), 6),
             round(1.0 - (float(y) + offset_y) / max(canvas_height - 1, 1), 6)]
            for x, y in polygon]


def _stable_id(plane_index: int, kind: str, polygon: list[list[float]]) -> str:
    payload = f"{plane_index}:{kind}:" + ";".join(
        f"{point[0]:.4f},{point[1]:.4f}" for point in polygon)
    return hashlib.sha1(payload.encode()).hexdigest()[:16]


def _load_grounding():
    import torch
    from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor

    # Transformers 4.57 usa questa guardia anche nel processor CPU; Torch 2.2
    # espone `torch.compiler` ma non ancora il metodo. In inferenza eager vale False.
    if not hasattr(torch.compiler, "is_compiling"):
        torch.compiler.is_compiling = lambda: False
    processor = AutoProcessor.from_pretrained(_DETECTOR_MODEL, use_fast=False)
    model = AutoModelForZeroShotObjectDetection.from_pretrained(_DETECTOR_MODEL)
    model.eval()
    return torch, processor, model


def _load_sam2():
    import torch
    from transformers import Sam2Model, Sam2Processor

    if not hasattr(torch.compiler, "is_compiling"):
        torch.compiler.is_compiling = lambda: False
    processor = Sam2Processor.from_pretrained(_SEGMENTER_MODEL, use_fast=False)
    model = Sam2Model.from_pretrained(_SEGMENTER_MODEL)
    model.eval()
    return torch, processor, model


def _detect_boxes(image: Image.Image, runtime) -> list[dict]:
    torch, processor, model = runtime
    inputs = processor(images=image, text=_PROMPT_LABELS, return_tensors="pt")
    with torch.inference_mode():
        outputs = model(**inputs)
    result = processor.post_process_grounded_object_detection(
        outputs, inputs.input_ids,
        # Il computo richiede alto richiamo: i falsi positivi sono revisionabili,
        # mentre un'apertura non proposta non può essere recuperata da SAM2.
        threshold=float(os.environ.get("ACRO_OPENING_BOX_THRESHOLD", "0.20")),
        text_threshold=float(os.environ.get("ACRO_OPENING_TEXT_THRESHOLD", "0.17")),
        target_sizes=[image.size[::-1]],
    )[0]
    labels = result.get("text_labels")
    if labels is None:
        labels = result.get("labels")
    if labels is None:
        labels = []
    proposals = []
    for box, score, label in zip(result["boxes"], result["scores"], labels):
        coordinates = [float(value) for value in box.tolist()]
        coordinates = [
            min(max(coordinates[0], 0.0), float(image.width)),
            min(max(coordinates[1], 0.0), float(image.height)),
            min(max(coordinates[2], 0.0), float(image.width)),
            min(max(coordinates[3], 0.0), float(image.height)),
        ]
        proposals.append({
            "box": coordinates,
            "score": float(score.item()),
            "label": str(label),
        })
    return _deduplicate(proposals)


def _axis_starts(length: int, tile_size: int, overlap: int) -> list[int]:
    if length <= tile_size:
        return [0]
    step = max(tile_size - overlap, 1)
    starts = list(range(0, length - tile_size + 1, step))
    last = length - tile_size
    if starts[-1] != last:
        starts.append(last)
    return starts


def _tile_bounds(
    image_size: tuple[int, int], tile_size: int, overlap: int,
) -> list[tuple[int, int, int, int]]:
    width, height = image_size
    tile_size = max(int(tile_size), 256)
    overlap = min(max(int(overlap), 0), tile_size - 1)
    return [
        (x, y, min(x + tile_size, width), min(y + tile_size, height))
        for y in _axis_starts(height, tile_size, overlap)
        for x in _axis_starts(width, tile_size, overlap)
    ]


def _detect_boxes_tiled(
    image: Image.Image, runtime, *, tile_size: int, overlap: int,
    detector: Callable = _detect_boxes,
) -> list[dict]:
    """Scansiona tutto il piano a tile sovrapposti e riporta i box in pixel 4K."""
    proposals = []
    for x0, y0, x1, y1 in _tile_bounds(image.size, tile_size, overlap):
        tile = image.crop((x0, y0, x1, y1))
        for raw in detector(tile, runtime):
            box = [
                float(raw["box"][0]) + x0, float(raw["box"][1]) + y0,
                float(raw["box"][2]) + x0, float(raw["box"][3]) + y0,
            ]
            center_x = (box[0] + box[2]) * 0.5
            center_y = (box[1] + box[3]) * 0.5
            core_left = x0 + overlap * 0.5 if x0 > 0 else 0.0
            core_right = x1 - overlap * 0.5 if x1 < image.width else float(image.width)
            core_top = y0 + overlap * 0.5 if y0 > 0 else 0.0
            core_bottom = y1 - overlap * 0.5 if y1 < image.height else float(image.height)
            if not (core_left <= center_x <= core_right
                    and core_top <= center_y <= core_bottom):
                continue
            proposals.append({**raw, "box": box, "_tile": (x0, y0, x1, y1)})
    return _deduplicate(proposals)


def _segment_boxes(image: Image.Image, boxes: list[list[float]], runtime) -> list[np.ndarray]:
    if not boxes:
        return []
    torch, processor, model = runtime
    inputs = processor(images=image, input_boxes=[boxes], return_tensors="pt")
    with torch.inference_mode():
        outputs = model(**inputs, multimask_output=False)
    masks = processor.post_process_masks(outputs.pred_masks.cpu(), inputs["original_sizes"])[0]
    return [np.asarray(mask).squeeze() for mask in masks]


def _mask_fills_tile(mask: np.ndarray) -> bool:
    """Riconosce quando SAM ha segmentato il tassello anziche un'apertura."""
    binary = np.asarray(mask).squeeze() > 0
    if binary.ndim != 2 or not binary.any() or float(binary.mean()) < 0.30:
        return False
    height, width = binary.shape
    margin = max(2, int(round(min(height, width) * 0.003)))
    touches = (
        bool(binary[:, :margin].any()),
        bool(binary[:, width - margin:].any()),
        bool(binary[:margin, :].any()),
        bool(binary[height - margin:, :].any()),
    )
    return sum(touches) >= 3


def _segment_polygons_tiled(
    image: Image.Image, proposals: list[dict], runtime,
    segmenter: Callable = _segment_boxes,
) -> list[list[list[float]]]:
    """Segmenta per tile e converte subito le maschere in coordinate globali."""
    if not proposals:
        return []
    grouped: dict[tuple[int, int, int, int], list[tuple[int, dict]]] = {}
    full = (0, 0, image.width, image.height)
    for index, proposal in enumerate(proposals):
        bounds = tuple(proposal.get("_tile") or full)
        grouped.setdefault(bounds, []).append((index, proposal))

    output: list[list[list[float]]] = [[] for _ in proposals]
    for (x0, y0, x1, y1), items in grouped.items():
        tile = image.crop((x0, y0, x1, y1))
        local_boxes = [
            [item["box"][0] - x0, item["box"][1] - y0,
             item["box"][2] - x0, item["box"][3] - y0]
            for _, item in items
        ]
        masks = segmenter(tile, local_boxes, runtime)
        for (index, _), mask in zip(items, masks):
            local = (np.asarray(mask).squeeze() > 0).astype(np.uint8)
            expected = (y1 - y0, x1 - x0)
            if local.shape != expected:
                local = cv2.resize(
                    local, expected[::-1], interpolation=cv2.INTER_NEAREST)
            if _mask_fills_tile(local):
                continue
            output[index] = _mask_polygon(
                local,
                expected,
                offset=(x0, y0),
                canvas_size=(image.height, image.width),
            )
    return output


def _read_texture(path: Path) -> tuple[Image.Image, np.ndarray | None]:
    raw = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if raw is None:
        raise DetectionError(f"Texture non leggibile: {path.name}")
    alpha = raw[:, :, 3] if raw.ndim == 3 and raw.shape[2] == 4 else None
    if raw.ndim == 2:
        rgb = cv2.cvtColor(raw, cv2.COLOR_GRAY2RGB)
    elif raw.shape[2] == 4:
        rgb = cv2.cvtColor(raw, cv2.COLOR_BGRA2RGB)
    else:
        rgb = cv2.cvtColor(raw, cv2.COLOR_BGR2RGB)
    return Image.fromarray(rgb), alpha


def run_detection_job(session_id: str) -> None:
    try:
        detect_openings(session_id)
    except Exception as exc:
        _set_job(session_id, "failed", 1.0, "Rilevamento non riuscito", str(exc)[:500])


def detect_openings(
    session_id: str,
    grounding_loader: Callable = _load_grounding,
    sam_loader: Callable = _load_sam2,
) -> dict:
    """Esegue Grounding DINO e SAM2 in due passate sequenziali."""
    with _INFERENCE_LOCK:
        sess = session_store.get_session(session_id)
        if sess is None:
            raise InputsMissing("Sessione non trovata")
        projection = _projection(sess)
        planes = projection.get("planes", [])
        files = _file_map(projection)
        tile_size = int(os.environ.get("ACRO_OPENING_TILE_SIZE", "2048"))
        tile_overlap = int(os.environ.get("ACRO_OPENING_TILE_OVERLAP", "384"))

        with tempfile.TemporaryDirectory(prefix="acro_openings_") as td:
            root = Path(td)
            textures: list[tuple[dict, Path]] = []
            for plane in planes:
                filename = Path(plane.get("file", "")).name
                remote = files.get(filename)
                if not filename or not remote:
                    continue
                local = root / filename
                local.write_bytes(storage_service.download_bytes(remote["path"]))
                textures.append((plane, local))
            if not textures:
                raise InputsMissing("Il bundle non contiene texture dei piani leggibili")

            _set_job(session_id, "running", 0.04, "Carico Grounding DINO")
            grounding = grounding_loader()
            proposals_by_plane: dict[int, list[dict]] = {}
            for done, (plane, path) in enumerate(textures, 1):
                image, _ = _read_texture(path)
                proposals = _detect_boxes_tiled(
                    image, grounding, tile_size=tile_size, overlap=tile_overlap)
                proposals_by_plane[int(plane["index"])] = proposals
                _set_job(session_id, "running", 0.05 + 0.38 * done / len(textures),
                         f"Cerco aperture: faccia {done}/{len(textures)}")
            del grounding
            gc.collect()

            _set_job(session_id, "running", 0.46, "Carico SAM2")
            sam = sam_loader()
            openings = []
            min_area = float(os.environ.get("ACRO_OPENING_MIN_AREA_M2", "0.08"))
            for done, (plane, path) in enumerate(textures, 1):
                plane_index = int(plane["index"])
                proposals = proposals_by_plane.get(plane_index, [])
                image, _ = _read_texture(path)
                polygons = _segment_polygons_tiled(image, proposals, sam)
                for proposal, polygon in zip(proposals, polygons):
                    kind = _opening_type(proposal["label"])
                    candidate = {
                        "id": _stable_id(plane_index, kind, polygon),
                        "plane_index": plane_index,
                        "type": kind,
                        "polygon_uv": polygon,
                        "confidence": round(proposal["score"], 4),
                        "area_m2": 0.0,
                        "excluded": True,
                        "source": "grounded_sam2",
                    }
                    candidate["area_m2"] = round(_opening_area_m2(candidate, plane), 3)
                    if len(polygon) >= 3 and candidate["area_m2"] >= min_area:
                        openings.append(candidate)
                _set_job(session_id, "running", 0.48 + 0.47 * done / len(textures),
                         f"Segmento aperture: faccia {done}/{len(textures)}")
            del sam
            gc.collect()

        document = {
            **_totals(projection, openings),
            "detector_model": _DETECTOR_MODEL,
            "segmenter_model": _SEGMENTER_MODEL,
            "updated_at": _now_iso(),
        }
        latest = session_store.get_session(session_id) or sess
        result = latest.get("result") or {}
        result["metric_openings"] = document
        session_store.update_session(session_id, {"result": result})
        _set_job(session_id, "complete", 1.0, f"Rilevate {len(openings)} aperture")
        return _public_result(session_store.get_session(session_id) or latest)
