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
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

import cv2
import numpy as np
from PIL import Image

from . import session_store, storage_service

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


class InputsMissing(RuntimeError):
    pass


class DetectionError(RuntimeError):
    pass


_ACTIVE_JOB_STATES = {"queued", "running"}
_JOB_STALE_SECONDS = int(os.environ.get("ACRO_OPENING_STALE_SECONDS", "7200"))
_INFERENCE_LOCK = threading.Lock()
_DETECTOR_MODEL = os.environ.get(
    "ACRO_OPENING_DETECTOR_MODEL", "IDEA-Research/grounding-dino-tiny")
_FACADE_DETECTOR_MODEL = os.environ.get(
    "ACRO_OPENING_FACADE_DETECTOR_MODEL",
    "florence-community/Florence-2-base-ft",
)
_FACADE_DETECTOR_REVISION = os.environ.get(
    "ACRO_OPENING_FACADE_DETECTOR_REVISION",
    "0b03b6f15a4a211370fb204aee4e7dd48887ea37",
)
_DETECTION_PIPELINE = os.environ.get(
    "ACRO_OPENING_PIPELINE", "florence_ground_hybrid")
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
_FLORENCE_PROMPTS = ("window", "door", "shop window")


def _detector_label() -> str:
    if _DETECTION_PIPELINE == "florence_ground_hybrid":
        return f"{_FACADE_DETECTOR_MODEL}+{_DETECTOR_MODEL}"
    return _DETECTOR_MODEL


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def uses_mac_worker() -> bool:
    """L'inferenza pesante gira sul Mac salvo override esplicito per sviluppo."""
    return os.environ.get("ACRO_OPENING_EXECUTOR", "mac").lower() != "inline"


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
    started_at = previous.get("started_at")
    if state == "queued" or not started_at:
        started_at = now
    job_id = str(uuid.uuid4()) if state == "queued" else previous.get("job_id")
    result["opening_detection_job"] = {
        "job_id": job_id,
        "executor": "mac" if uses_mac_worker() else "inline",
        "state": state,
        "progress": min(max(float(progress), 0.0), 1.0),
        "message": message,
        "error": error,
        "started_at": started_at,
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


def _polygon_fills_plane(
    points: list[list[float]] | list[tuple[float, float]],
) -> bool:
    if len(points) < 3 or _polygon_area_uv(points) < 0.45:
        return False
    us = [float(point[0]) for point in points]
    vs = [float(point[1]) for point in points]
    touches = (
        min(us) <= 0.02,
        max(us) >= 0.98,
        min(vs) <= 0.02,
        max(vs) >= 0.98,
    )
    return sum(touches) >= 3


def _trim_map(sess: dict) -> dict[int, tuple[float, float]]:
    document = (sess.get("result") or {}).get("metric_trims") or {}
    return {
        int(item["plane_index"]): (float(item["bottom"]), float(item["top"]))
        for item in document.get("trims", [])
        if isinstance(item, dict) and "plane_index" in item
    }


def _clip_polygon_y(
    points: list[list[float]] | list[tuple[float, float]],
    bottom: float,
    top: float,
) -> list[list[float]]:
    polygon = [[float(point[0]), float(point[1])] for point in points]

    def clip(source: list[list[float]], boundary: float, keep_above: bool):
        if not source:
            return []
        output = []
        previous = source[-1]
        previous_inside = previous[1] >= boundary if keep_above else previous[1] <= boundary
        for current in source:
            current_inside = current[1] >= boundary if keep_above else current[1] <= boundary
            if current_inside != previous_inside:
                denominator = current[1] - previous[1]
                ratio = 0.0 if abs(denominator) < 1e-12 else \
                    (boundary - previous[1]) / denominator
                output.append([
                    previous[0] + (current[0] - previous[0]) * ratio,
                    boundary,
                ])
            if current_inside:
                output.append(current)
            previous, previous_inside = current, current_inside
        return output

    return clip(clip(polygon, bottom, True), top, False)


def _opening_area_m2(
    opening: dict,
    plane: dict,
    trim: tuple[float, float] = (0.0, 1.0),
) -> float:
    rectangle_area = float(plane.get("width_m", 0.0)) * float(plane.get("height_m", 0.0))
    polygon = _clip_polygon_y(opening.get("polygon_uv") or [], *trim)
    return _polygon_area_uv(polygon) * rectangle_area


def _union_area_m2(
    openings: list[dict],
    planes: dict[int, dict],
    trims: dict[int, tuple[float, float]] | None = None,
) -> float:
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
        trim = (trims or {}).get(plane_index, (0.0, 1.0))
        for opening in selected:
            points = np.asarray([
                [round(min(max(float(u), 0.0), 1.0) * (width - 1)),
                 round((1.0 - min(max(float(v), 0.0), 1.0)) * (height - 1))]
                for u, v in _clip_polygon_y(
                    opening.get("polygon_uv") or [], *trim)
            ], np.int32)
            if len(points) >= 3:
                cv2.fillPoly(mask, [points], 255)
        rectangle = float(plane.get("width_m", 0.0)) * float(plane.get("height_m", 0.0))
        total += float(np.count_nonzero(mask)) / float(width * height) * rectangle
    return total


def _totals(
    projection: dict,
    openings: list[dict],
    trims: dict[int, tuple[float, float]] | None = None,
) -> dict:
    planes = _plane_map(projection)
    trims = trims or {}
    normalized = []
    for raw in openings:
        item = dict(raw)
        plane = planes.get(int(item.get("plane_index", -1)))
        if not plane:
            continue
        item["area_m2"] = round(_opening_area_m2(
            item, plane, trims.get(int(item["plane_index"]), (0.0, 1.0))), 3)
        normalized.append(item)
    if trims:
        gross = sum(
            float(plane.get("area_m2", 0.0))
            * max(0.0, trims.get(index, (0.0, 1.0))[1]
                  - trims.get(index, (0.0, 1.0))[0])
            for index, plane in planes.items()
        )
    else:
        gross = float(projection.get("total_area_m2", 0.0)) or sum(
            float(plane.get("area_m2", 0.0)) for plane in planes.values()
        )
    excluded = min(_union_area_m2(normalized, planes, trims), gross)
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
        "detector_model": document.get("detector_model", _detector_label()),
        "segmenter_model": document.get("segmenter_model", _SEGMENTER_MODEL),
    }


def start_detection(session_id: str) -> tuple[dict, bool]:
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")
    _projection(sess)
    job = (sess.get("result") or {}).get("opening_detection_job") or {}
    if job.get("state") in _ACTIVE_JOB_STATES and not _job_is_stale(job):
        if uses_mac_worker() and job.get("executor") != "mac":
            _set_job(session_id, "queued", 0.0, "Trasferisco il rilevamento al Mac")
            return _public_result(session_store.get_session(session_id) or sess), True
        return _public_result(sess), False
    _set_job(session_id, "queued", 0.0, "Rilevamento aperture accodato")
    return _public_result(session_store.get_session(session_id) or sess), True


def _worker_payload(sess: dict) -> dict:
    """Restituisce al Mac soltanto manifesto leggero e URL firmati delle texture."""
    projection = _projection(sess)
    files = _file_map(projection)
    textures = []
    for plane in projection.get("planes", []):
        name = Path(plane.get("file", "")).name
        record = files.get(name)
        if not name or not record or not record.get("path"):
            continue
        textures.append({
            "plane_index": int(plane["index"]),
            "name": name,
            "url": storage_service.signed_url(
                record["path"], expires_in_sec=12 * 60 * 60),
            "size_bytes": record.get("size"),
            "sha256": record.get("checksum"),
        })
    if not textures:
        raise InputsMissing("Il bundle non contiene texture dei piani leggibili")
    result = sess.get("result") or {}
    job = result.get("opening_detection_job") or {}
    return {
        "session_id": sess["id"],
        "job_id": job.get("job_id"),
        "projection": {
            "planes": projection.get("planes", []),
            "total_area_m2": projection.get("total_area_m2", 0.0),
            "scale_m_per_mesh_unit": projection.get("scale_m_per_mesh_unit", 1.0),
        },
        "textures": textures,
        "config": {
            "tile_size": int(os.environ.get("ACRO_OPENING_TILE_SIZE", "2048")),
            "tile_overlap": int(os.environ.get("ACRO_OPENING_TILE_OVERLAP", "384")),
            "min_area_m2": float(os.environ.get("ACRO_OPENING_MIN_AREA_M2", "0.08")),
            "pipeline": _DETECTION_PIPELINE,
            "detector_model": _DETECTOR_MODEL,
            "facade_detector_model": _FACADE_DETECTOR_MODEL,
            "ground_fraction": float(os.environ.get(
                "ACRO_OPENING_GROUND_FRACTION", "0.24")),
            "ground_min_aspect": float(os.environ.get(
                "ACRO_OPENING_GROUND_MIN_ASPECT", "0.25")),
            "segmenter_model": _SEGMENTER_MODEL,
        },
    }


def claim_next_worker_job() -> dict:
    now = _now_iso()
    sess = session_store.claim_next_opening_job({
        "state": "running",
        "executor": "mac",
        "progress": 0.02,
        "message": "Worker Mac: preparo le texture",
        "error": "",
        "updated_at": now,
    })
    if sess is None:
        return {}
    try:
        return _worker_payload(sess)
    except Exception as exc:
        _set_job(sess["id"], "failed", 1.0, "Input AI non validi", str(exc)[:500])
        raise


def update_worker_progress(
    session_id: str, job_id: str, progress: float, message: str,
) -> None:
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")
    current = ((sess.get("result") or {}).get("opening_detection_job") or {})
    if current.get("job_id") != job_id or current.get("state") != "running":
        raise DetectionError("Job aperture non piu corrente")
    _set_job(session_id, "running", progress, message)


def _validated_worker_openings(projection: dict, openings: list[dict]) -> list[dict]:
    planes = _plane_map(projection)
    validated = []
    seen = set()
    allowed_types = {"window", "door", "shop_window", "unknown"}
    for raw in openings:
        plane_index = int(raw.get("plane_index", -1))
        polygon = [[float(u), float(v)] for u, v in raw.get("polygon_uv", [])]
        if plane_index not in planes or len(polygon) < 3:
            raise DetectionError("Risultato AI riferito a un piano non valido")
        if any(not (0.0 <= value <= 1.0) for point in polygon for value in point):
            raise DetectionError("Coordinate apertura fuori dal piano")
        kind = str(raw.get("type", "unknown"))
        if kind not in allowed_types:
            kind = "unknown"
        identifier = _stable_id(plane_index, kind, polygon)
        if identifier in seen:
            continue
        seen.add(identifier)
        validated.append({
            "id": identifier,
            "plane_index": plane_index,
            "type": kind,
            "polygon_uv": polygon,
            "confidence": min(max(float(raw.get("confidence", 0.0)), 0.0), 1.0),
            "area_m2": 0.0,
            "excluded": True,
            "source": "grounded_sam2",
        })
    return validated


def complete_worker_job(session_id: str, job_id: str, openings: list[dict]) -> dict:
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")
    result = sess.get("result") or {}
    current = result.get("opening_detection_job") or {}
    if current.get("job_id") != job_id or current.get("state") != "running":
        raise DetectionError("Risultato AI obsoleto o gia sostituito")
    projection = _projection(sess)
    validated = _validated_worker_openings(projection, openings)
    document = {
        **_totals(projection, validated, _trim_map(sess)),
        "detector_model": _detector_label(),
        "segmenter_model": _SEGMENTER_MODEL,
        "updated_at": _now_iso(),
    }
    result["metric_openings"] = document
    session_store.update_session(session_id, {"result": result})
    _set_job(session_id, "complete", 1.0, f"Rilevate {len(validated)} aperture")
    return _public_result(session_store.get_session(session_id) or sess)


def fail_worker_job(session_id: str, job_id: str, error: str) -> None:
    sess = session_store.get_session(session_id)
    if sess is None:
        return
    current = ((sess.get("result") or {}).get("opening_detection_job") or {})
    if current.get("job_id") == job_id:
        _set_job(
            session_id, "failed", 1.0,
            "Rilevamento non riuscito", error[:500],
        )


def detection_status(session_id: str) -> Optional[dict]:
    sess = session_store.get_session(session_id)
    if sess is not None:
        job = (sess.get("result") or {}).get("opening_detection_job") or {}
        if (job.get("state") in _ACTIVE_JOB_STATES and uses_mac_worker()
                and job.get("executor") != "mac"):
            _set_job(session_id, "queued", 0.0, "Trasferisco il rilevamento al Mac")
            sess = session_store.get_session(session_id) or sess
        elif _job_is_stale(job):
            _set_job(session_id, "failed", 1.0, "Rilevamento interrotto",
                     "Il worker non ha aggiornato il lavoro; rilancia il rilevamento.")
            sess = session_store.get_session(session_id) or sess
    return _public_result(sess) if sess is not None else None


def metric_trims_status(session_id: str) -> Optional[dict]:
    sess = session_store.get_session(session_id)
    if sess is None:
        return None
    result = sess.get("result") or {}
    projection = result.get("projection") or {}
    document = result.get("metric_trims") or {"trims": []}
    totals = _totals(
        projection,
        (result.get("metric_openings") or {}).get("openings", []),
        _trim_map(sess),
    )
    return {
        "trims": document.get("trims", []),
        "gross_area_m2": totals["gross_area_m2"],
        "excluded_area_m2": totals["excluded_area_m2"],
        "net_area_m2": totals["net_area_m2"],
    }


def save_metric_trims(session_id: str, trims: list[dict]) -> dict:
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")
    projection = _projection(sess)
    plane_indices = set(_plane_map(projection))
    unknown = sorted(
        int(item["plane_index"]) for item in trims
        if int(item["plane_index"]) not in plane_indices
    )
    if unknown:
        raise InputsMissing(
            "Piani non presenti nella proiezione: "
            + ", ".join(str(index) for index in unknown)
        )
    result = sess.get("result") or {}
    result["metric_trims"] = {
        "schema": "acro.metric-trims/v1",
        "trims": trims,
        "updated_at": _now_iso(),
    }
    opening_document = result.get("metric_openings") or {}
    totals = _totals(
        projection,
        opening_document.get("openings", []),
        {int(item["plane_index"]): (float(item["bottom"]), float(item["top"]))
         for item in trims},
    )
    if "openings" in opening_document:
        result["metric_openings"] = {**opening_document, **totals}
    session_store.update_session(session_id, {"result": result})
    return {
        "trims": trims,
        "gross_area_m2": totals["gross_area_m2"],
        "excluded_area_m2": totals["excluded_area_m2"],
        "net_area_m2": totals["net_area_m2"],
    }


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
        **_totals(projection, reviewed, _trim_map(sess)),
        "detector_model": _detector_label(),
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


def _box_area(box: list[float]) -> float:
    return max(box[2] - box[0], 0.0) * max(box[3] - box[1], 0.0)


def _overlap_over_smaller(a: list[float], b: list[float]) -> float:
    x0, y0 = max(a[0], b[0]), max(a[1], b[1])
    x1, y1 = min(a[2], b[2]), min(a[3], b[3])
    intersection = max(x1 - x0, 0.0) * max(y1 - y0, 0.0)
    return intersection / max(min(_box_area(a), _box_area(b)), 1e-9)


def _same_nested_opening(a: list[float], b: list[float]) -> bool:
    area_a, area_b = _box_area(a), _box_area(b)
    ratio = max(area_a, area_b) / max(min(area_a, area_b), 1e-9)
    center_a = ((a[0] + a[2]) * 0.5, (a[1] + a[3]) * 0.5)
    center_b = ((b[0] + b[2]) * 0.5, (b[1] + b[3]) * 0.5)
    scale = max(
        min(a[2] - a[0], b[2] - b[0]),
        min(a[3] - a[1], b[3] - b[1]),
        1e-9,
    )
    center_distance = (
        (center_a[0] - center_b[0]) ** 2
        + (center_a[1] - center_b[1]) ** 2
    ) ** 0.5 / scale
    return (
        _overlap_over_smaller(a, b) >= 0.72
        and ratio <= 2.8
        and center_distance <= 0.55
    )


def _deduplicate_nested(proposals: list[dict]) -> list[dict]:
    """Fonde box interno/esterno della stessa apertura, tenendo quello interno."""
    kept = []
    for proposal in sorted(proposals, key=lambda item: _box_area(item["box"])):
        if any(_same_nested_opening(proposal["box"], item["box"])
               for item in kept):
            continue
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
    from transformers.models.grounding_dino import modeling_grounding_dino

    # Transformers 4.57 usa questa guardia anche nel processor CPU; Torch 2.2
    # espone `torch.compiler` ma non ancora il metodo. In inferenza eager vale False.
    if not hasattr(torch.compiler, "is_compiling"):
        torch.compiler.is_compiling = lambda: False
    if not getattr(
        modeling_grounding_dino.generate_masks_with_special_tokens_and_transfer_map,
        "_acro_mps_safe", False,
    ):
        original_mask_builder = (
            modeling_grounding_dino.generate_masks_with_special_tokens_and_transfer_map)

        def mps_safe_mask_builder(input_ids):
            # MPS non garantisce qui lo stesso ordinamento di torch.nonzero e la
            # funzione Transformers usa un previous_col globale. Costruiamo le
            # piccole maschere testuali su CPU e rimandiamole al modello Metal.
            if input_ids.device.type != "mps":
                return original_mask_builder(input_ids)
            attention, positions = original_mask_builder(input_ids.cpu())
            return attention.to(input_ids.device), positions.to(input_ids.device)

        mps_safe_mask_builder._acro_mps_safe = True
        modeling_grounding_dino.generate_masks_with_special_tokens_and_transfer_map = (
            mps_safe_mask_builder)
    processor = AutoProcessor.from_pretrained(_DETECTOR_MODEL, use_fast=False)
    model = AutoModelForZeroShotObjectDetection.from_pretrained(_DETECTOR_MODEL)
    device = _inference_device(torch)
    model.to(device).eval()
    return torch, processor, model, device


def _load_florence():
    import torch
    from transformers import AutoProcessor, Florence2ForConditionalGeneration

    processor = AutoProcessor.from_pretrained(
        _FACADE_DETECTOR_MODEL,
        revision=_FACADE_DETECTOR_REVISION,
    )
    model = Florence2ForConditionalGeneration.from_pretrained(
        _FACADE_DETECTOR_MODEL,
        revision=_FACADE_DETECTOR_REVISION,
        attn_implementation="eager",
    )
    device = _inference_device(torch)
    model.to(device).eval()
    return torch, processor, model, device


def _load_sam2():
    import torch
    from transformers import Sam2Model, Sam2Processor

    if not hasattr(torch.compiler, "is_compiling"):
        torch.compiler.is_compiling = lambda: False
    processor = Sam2Processor.from_pretrained(_SEGMENTER_MODEL, use_fast=False)
    model = Sam2Model.from_pretrained(_SEGMENTER_MODEL)
    device = _inference_device(torch)
    model.to(device).eval()
    return torch, processor, model, device


def _inference_device(torch) -> str:
    requested = os.environ.get("ACRO_AI_DEVICE", "auto").strip().lower()
    if requested != "auto":
        return requested
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def _runtime_parts(runtime):
    if len(runtime) == 4:
        return runtime
    torch, processor, model = runtime
    return torch, processor, model, "cpu"


def _detect_boxes(image: Image.Image, runtime) -> list[dict]:
    torch, processor, model, device = _runtime_parts(runtime)
    inputs = processor(images=image, text=_PROMPT_LABELS, return_tensors="pt")
    if device != "cpu":
        inputs = inputs.to(device)
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


def _is_full_face_box(box: list[float], image_size: tuple[int, int]) -> bool:
    width, height = image_size
    if _box_area(box) < width * height * 0.55:
        return False
    margin_x, margin_y = width * 0.02, height * 0.02
    touches = (
        box[0] <= margin_x,
        box[2] >= width - margin_x,
        box[1] <= margin_y,
        box[3] >= height - margin_y,
    )
    return sum(touches) >= 3


def _detect_boxes_florence(image: Image.Image, runtime) -> list[dict]:
    torch, processor, model, device = _runtime_parts(runtime)
    proposals = []
    task = "<OPEN_VOCABULARY_DETECTION>"
    for query in _FLORENCE_PROMPTS:
        inputs = processor(
            text=task + query, images=image, return_tensors="pt")
        if device != "cpu":
            inputs = inputs.to(device)
        with torch.inference_mode():
            generated = model.generate(
                **inputs,
                max_new_tokens=1024,
                num_beams=3,
                do_sample=False,
            )
        text = processor.batch_decode(
            generated, skip_special_tokens=False)[0]
        parsed = processor.post_process_generation(
            text, task=task, image_size=image.size).get(task, {})
        for box in parsed.get("bboxes", []):
            coordinates = [float(value) for value in box]
            if _is_full_face_box(coordinates, image.size):
                continue
            proposals.append({
                "box": coordinates,
                "score": 0.8,
                "label": query,
                "_tile": (0, 0, image.width, image.height),
            })
    return _deduplicate_nested(_deduplicate(proposals))


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


def _detect_ground_boxes_tiled(
    image: Image.Image,
    runtime,
    *,
    tile_size: int,
    overlap: int,
    ground_fraction: float,
    min_aspect: float,
) -> list[dict]:
    if image.height <= 0 or image.width / image.height < min_aspect:
        return []
    fraction = min(max(float(ground_fraction), 0.10), 0.50)
    y_offset = int(round(image.height * (1.0 - fraction)))
    crop = image.crop((0, y_offset, image.width, image.height))
    proposals = _detect_boxes_tiled(
        crop, runtime, tile_size=tile_size, overlap=overlap)
    remapped = []
    for proposal in proposals:
        x0, y0, x1, y1 = proposal["_tile"]
        remapped.append({
            **proposal,
            "box": [
                proposal["box"][0], proposal["box"][1] + y_offset,
                proposal["box"][2], proposal["box"][3] + y_offset,
            ],
            "_tile": (x0, y0 + y_offset, x1, y1 + y_offset),
        })
    return remapped


def _segment_boxes(image: Image.Image, boxes: list[list[float]], runtime) -> list[np.ndarray]:
    if not boxes:
        return []
    torch, processor, model, device = _runtime_parts(runtime)
    inputs = processor(images=image, input_boxes=[boxes], return_tensors="pt")
    original_sizes = inputs["original_sizes"].cpu()
    if device != "cpu":
        inputs = inputs.to(device)
    with torch.inference_mode():
        outputs = model(**inputs, multimask_output=False)
    masks = processor.post_process_masks(outputs.pred_masks.cpu(), original_sizes)[0]
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


def detect_openings_from_textures(
    projection: dict,
    texture_paths: dict[int, Path],
    *,
    progress: Callable[[float, str], None] | None = None,
    facade_loader: Callable = _load_florence,
    grounding_loader: Callable = _load_grounding,
    sam_loader: Callable = _load_sam2,
    tile_size: int = 2048,
    tile_overlap: int = 384,
    min_area_m2: float = 0.08,
    pipeline: str = _DETECTION_PIPELINE,
    ground_fraction: float = 0.24,
    ground_min_aspect: float = 0.25,
) -> list[dict]:
    """Inferenza pura su file locali, usabile sia da Railway sia dal worker Mac."""
    report = progress or (lambda _value, _message: None)
    planes = [
        plane for plane in projection.get("planes", [])
        if int(plane.get("index", -1)) in texture_paths
    ]
    if not planes:
        raise InputsMissing("Il bundle non contiene texture dei piani leggibili")

    proposals_by_plane: dict[int, list[dict]] = {}
    use_hybrid = pipeline == "florence_ground_hybrid"
    facade_detector = None
    if use_hybrid:
        try:
            report(0.04, "Mac: carico Florence-2")
            facade_detector = facade_loader()
            for done, plane in enumerate(planes, 1):
                plane_index = int(plane["index"])
                image, _ = _read_texture(texture_paths[plane_index])
                proposals_by_plane[plane_index] = _detect_boxes_florence(
                    image, facade_detector)
                report(
                    0.05 + 0.25 * done / len(planes),
                    f"Mac: analizzo facciata {done}/{len(planes)}",
                )
        except Exception as exc:
            # Il job deve restare utilizzabile anche se il checkpoint Florence
            # non e disponibile sul worker: in tal caso torna alla scansione DINO.
            report(0.04, f"Mac: fallback Grounding DINO ({type(exc).__name__})")
            proposals_by_plane.clear()
            use_hybrid = False
        finally:
            if facade_detector is not None:
                del facade_detector
            gc.collect()

    report(0.31 if use_hybrid else 0.04, "Mac: carico Grounding DINO")
    grounding = grounding_loader()
    for done, plane in enumerate(planes, 1):
        plane_index = int(plane["index"])
        image, _ = _read_texture(texture_paths[plane_index])
        if use_hybrid:
            grounded = _detect_ground_boxes_tiled(
                image,
                grounding,
                tile_size=tile_size,
                overlap=tile_overlap,
                ground_fraction=ground_fraction,
                min_aspect=ground_min_aspect,
            )
            proposals_by_plane[plane_index] = _deduplicate_nested(
                proposals_by_plane.get(plane_index, []) + grounded)
            start, span = 0.32, 0.16
            message = f"Mac: controllo piano terra {done}/{len(planes)}"
        else:
            proposals_by_plane[plane_index] = _detect_boxes_tiled(
                image, grounding, tile_size=tile_size, overlap=tile_overlap)
            start, span = 0.05, 0.38
            message = f"Mac: cerco aperture, faccia {done}/{len(planes)}"
        report(start + span * done / len(planes), message)
    del grounding
    gc.collect()

    report(0.49 if use_hybrid else 0.46, "Mac: carico SAM2")
    sam = sam_loader()
    openings = []
    for done, plane in enumerate(planes, 1):
        plane_index = int(plane["index"])
        proposals = proposals_by_plane.get(plane_index, [])
        image, _ = _read_texture(texture_paths[plane_index])
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
            candidate["area_m2"] = round(
                _opening_area_m2(candidate, plane), 3)
            if (len(polygon) >= 3
                    and not _polygon_fills_plane(polygon)
                    and candidate["area_m2"] >= min_area_m2):
                openings.append(candidate)
        report(
            0.50 + 0.45 * done / len(planes),
            f"Mac: segmento aperture, faccia {done}/{len(planes)}",
        )
    del sam
    gc.collect()
    return openings


def detect_openings(
    session_id: str,
    facade_loader: Callable = _load_florence,
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
        with tempfile.TemporaryDirectory(prefix="acro_openings_") as td:
            root = Path(td)
            texture_paths: dict[int, Path] = {}
            for plane in planes:
                filename = Path(plane.get("file", "")).name
                remote = files.get(filename)
                if not filename or not remote:
                    continue
                local = root / filename
                local.write_bytes(storage_service.download_bytes(remote["path"]))
                texture_paths[int(plane["index"])] = local
            openings = detect_openings_from_textures(
                projection,
                texture_paths,
                progress=lambda value, message: _set_job(
                    session_id, "running", value, message.replace("Mac: ", "")),
                facade_loader=facade_loader,
                grounding_loader=grounding_loader,
                sam_loader=sam_loader,
                tile_size=int(os.environ.get("ACRO_OPENING_TILE_SIZE", "2048")),
                tile_overlap=int(os.environ.get("ACRO_OPENING_TILE_OVERLAP", "384")),
                min_area_m2=float(os.environ.get("ACRO_OPENING_MIN_AREA_M2", "0.08")),
                pipeline=_DETECTION_PIPELINE,
                ground_fraction=float(os.environ.get(
                    "ACRO_OPENING_GROUND_FRACTION", "0.24")),
                ground_min_aspect=float(os.environ.get(
                    "ACRO_OPENING_GROUND_MIN_ASPECT", "0.25")),
            )

        latest = session_store.get_session(session_id) or sess
        document = {
            **_totals(projection, openings, _trim_map(latest)),
            "detector_model": _detector_label(),
            "segmenter_model": _SEGMENTER_MODEL,
            "updated_at": _now_iso(),
        }
        result = latest.get("result") or {}
        result["metric_openings"] = document
        session_store.update_session(session_id, {"result": result})
        _set_job(session_id, "complete", 1.0, f"Rilevate {len(openings)} aperture")
        return _public_result(session_store.get_session(session_id) or latest)
