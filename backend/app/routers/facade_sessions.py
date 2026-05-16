"""Endpoint per gestione sessioni di scansione facciata."""
from __future__ import annotations
import json
import time
import uuid
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse

from ..models import (
    ARMetadata,
    CreateSessionResponse,
    ProcessRequest,
    ProcessResult,
    SessionState,
    UploadPhotoResponse,
)
from ..services import (
    measurement_service,
    rectification_service,
    segmentation_service,
    stitching_service,
)
from ..utils.image_io import session_dir, photos_dir, out_dir, write_session, read_session

router = APIRouter(prefix="/facade-sessions", tags=["facade-sessions"])


@router.post("", response_model=CreateSessionResponse, status_code=201)
def create_session():
    sid = uuid.uuid4().hex
    now = time.time()
    state = SessionState(session_id=sid, status="capturing", created_at=now, updated_at=now)
    session_dir(sid).mkdir(parents=True, exist_ok=True)
    photos_dir(sid).mkdir(parents=True, exist_ok=True)
    out_dir(sid).mkdir(parents=True, exist_ok=True)
    write_session(state)
    return CreateSessionResponse(session_id=sid, status=state.status)


@router.post("/{session_id}/photos", response_model=UploadPhotoResponse)
async def upload_photo(
    session_id: str,
    image: UploadFile = File(...),
    metadata: str = Form(...),
):
    state = read_session(session_id)
    if state is None:
        raise HTTPException(404, "Sessione non trovata")
    try:
        meta_obj = ARMetadata.model_validate_json(metadata)
    except Exception as e:  # pragma: no cover
        raise HTTPException(400, f"Metadata JSON non valido: {e}")

    ext = (image.filename or "photo.jpg").split(".")[-1].lower()
    if ext not in {"jpg", "jpeg", "png", "heic"}:
        ext = "jpg"
    filename = f"{meta_obj.order_index:04d}.{ext}"
    fpath = photos_dir(session_id) / filename
    fpath.write_bytes(await image.read())
    meta_path = photos_dir(session_id) / f"{meta_obj.order_index:04d}.json"
    meta_path.write_text(meta_obj.model_dump_json(indent=2))

    state.photos = [p for p in state.photos if p.order_index != meta_obj.order_index]
    state.photos.append(meta_obj)
    state.photos.sort(key=lambda p: p.order_index)
    state.updated_at = time.time()
    write_session(state)
    return UploadPhotoResponse(session_id=session_id, order_index=meta_obj.order_index, photos_count=len(state.photos))


@router.post("/{session_id}/process", response_model=ProcessResult)
def process_session(session_id: str, req: Optional[ProcessRequest] = None):
    state = read_session(session_id)
    if state is None:
        raise HTTPException(404, "Sessione non trovata")
    if len(state.photos) == 0:
        raise HTTPException(400, "Nessuna foto caricata")

    state.status = "processing"
    state.updated_at = time.time()
    write_session(state)

    photo_paths = sorted(photos_dir(session_id).glob("*.jpg")) + \
                  sorted(photos_dir(session_id).glob("*.jpeg")) + \
                  sorted(photos_dir(session_id).glob("*.png"))
    photo_paths = sorted(photo_paths)

    warnings: list[str] = []

    # 1) Stitching
    stitched_img, stitch_info = stitching_service.stitch_images([str(p) for p in photo_paths])
    if stitch_info.get("warning"):
        warnings.append(stitch_info["warning"])
    stitched_path = out_dir(session_id) / "stitched.jpg"
    stitching_service.save_image(stitched_img, stitched_path)

    # 2) Rectification (4 punti dal client o automatica)
    quad = req.facade_quad_pixels if req and req.facade_quad_pixels else None
    rectified_img, rect_info = rectification_service.rectify(stitched_img, quad=quad)
    rectified_path = out_dir(session_id) / "rectified.jpg"
    rectification_service.save_image(rectified_img, rectified_path)

    # 3) Segmentation (mock)
    openings = segmentation_service.segment_openings(rectified_img)

    # 4) Measurement
    measure = measurement_service.measure(
        rectified_img,
        openings,
        scale_factor_m_per_px=(req.scale_factor_meters_per_pixel if req else None),
    )

    result = ProcessResult(
        stitched_url=f"/facade-sessions/{session_id}/files/stitched.jpg",
        rectified_url=f"/facade-sessions/{session_id}/files/rectified.jpg",
        facade_polygon=rect_info.get("facade_polygon"),
        vanishing_points=rect_info.get("vanishing_points"),
        openings=openings,
        gross_area_pixels=measure["gross_area_pixels"],
        excluded_area_pixels=measure["excluded_area_pixels"],
        net_area_pixels=measure["net_area_pixels"],
        gross_area_m2=measure.get("gross_area_m2"),
        net_area_m2=measure.get("net_area_m2"),
        warnings=warnings,
    )

    state.status = "completed"
    state.result = result
    state.updated_at = time.time()
    write_session(state)
    return result


@router.get("/{session_id}/result", response_model=ProcessResult)
def get_result(session_id: str):
    state = read_session(session_id)
    if state is None:
        raise HTTPException(404, "Sessione non trovata")
    if state.result is None:
        raise HTTPException(409, "Nessun risultato: chiamare /process prima")
    return state.result


@router.get("/{session_id}/files/{filename}")
def get_file(session_id: str, filename: str):
    safe = filename.replace("..", "").replace("/", "")
    candidate = out_dir(session_id) / safe
    if not candidate.is_file():
        raise HTTPException(404, "File non trovato")
    return FileResponse(candidate)


@router.get("/{session_id}", response_model=SessionState)
def get_session(session_id: str):
    state = read_session(session_id)
    if state is None:
        raise HTTPException(404, "Sessione non trovata")
    return state
