"""Endpoint per gestione sessioni di scansione facciata.

Storage:
  - Foto originali e output (stitched/rectified) → Supabase Storage (bucket `facade-photos`).
  - Stato sessione + metadata foto → Supabase Postgres (tabelle facade_sessions, facade_photos).

Le immagini vengono scaricate temporaneamente in memoria per il processing OpenCV
e ricaricate come output. Niente persistenza locale.
"""
from __future__ import annotations
import json
import tempfile
from pathlib import Path
from typing import Optional

import cv2
import numpy as np
from fastapi import APIRouter, File, Form, HTTPException, UploadFile

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
    session_store,
    storage_service,
    stitching_service,
)

router = APIRouter(prefix="/facade-sessions", tags=["facade-sessions"])


@router.post("", response_model=CreateSessionResponse, status_code=201)
def create_session():
    row = session_store.create_session()
    return CreateSessionResponse(session_id=row["id"], status=row["status"])


@router.post("/{session_id}/photos", response_model=UploadPhotoResponse)
async def upload_photo(
    session_id: str,
    image: UploadFile = File(...),
    metadata: str = Form(...),
):
    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    try:
        meta_obj = ARMetadata.model_validate_json(metadata)
    except Exception as e:
        raise HTTPException(400, f"Metadata JSON non valido: {e}")

    image_bytes = await image.read()
    remote = storage_service.photo_path(session_id, meta_obj.order_index)
    storage_service.upload_bytes(remote, image_bytes, content_type="image/jpeg")

    session_store.upsert_photo(
        session_id=session_id,
        order_index=meta_obj.order_index,
        storage_path=remote,
        metadata=meta_obj.model_dump(),
    )

    photos = session_store.list_photos(session_id)
    return UploadPhotoResponse(
        session_id=session_id,
        order_index=meta_obj.order_index,
        photos_count=len(photos),
    )


@router.post("/{session_id}/process", response_model=ProcessResult)
def process_session(session_id: str, req: Optional[ProcessRequest] = None):
    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    photos = session_store.list_photos(session_id)
    if not photos:
        raise HTTPException(400, "Nessuna foto caricata")

    session_store.update_session(session_id, {"status": "processing"})

    # 1) Scarica le foto in una dir temporanea.
    images: list[np.ndarray] = []
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        local_paths: list[str] = []
        for p in photos:
            data = storage_service.download_bytes(p["storage_path"])
            local = td_path / Path(p["storage_path"]).name
            local.write_bytes(data)
            local_paths.append(str(local))

        # 2) Stitching
        stitched_img, stitch_info = stitching_service.stitch_images(local_paths)
        warnings: list[str] = []
        if stitch_info.get("warning"):
            warnings.append(stitch_info["warning"])

        # Carica stitched su Supabase Storage.
        ok, buf = cv2.imencode(".jpg", stitched_img, [cv2.IMWRITE_JPEG_QUALITY, 90])
        if not ok:
            raise HTTPException(500, "Encoding stitched fallito")
        stitched_remote = storage_service.out_path(session_id, "stitched.jpg")
        storage_service.upload_bytes(stitched_remote, buf.tobytes())

        # 3) Rectification.
        quad = req.facade_quad_pixels if req and req.facade_quad_pixels else None
        rectified_img, rect_info = rectification_service.rectify(stitched_img, quad=quad)
        ok, buf = cv2.imencode(".jpg", rectified_img, [cv2.IMWRITE_JPEG_QUALITY, 90])
        if not ok:
            raise HTTPException(500, "Encoding rectified fallito")
        rectified_remote = storage_service.out_path(session_id, "rectified.jpg")
        storage_service.upload_bytes(rectified_remote, buf.tobytes())

        # 4) Segmentazione (mock per ora)
        openings = segmentation_service.segment_openings(rectified_img)

        # 5) Measurement
        scale = req.scale_factor_meters_per_pixel if req else None
        measure = measurement_service.measure(rectified_img, openings, scale_factor_m_per_px=scale)

    # 6) Compone risultato e salva.
    result = ProcessResult(
        stitched_url=storage_service.signed_url(stitched_remote),
        rectified_url=storage_service.signed_url(rectified_remote),
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
    session_store.update_session(session_id, {"status": "completed", "result": result.model_dump()})
    return result


@router.get("/{session_id}/result", response_model=ProcessResult)
def get_result(session_id: str):
    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    if not sess.get("result"):
        raise HTTPException(409, "Nessun risultato: chiamare /process prima")
    # I signed URL salvati potrebbero essere scaduti — li rigeneriamo.
    result_dict = sess["result"]
    if result_dict.get("stitched_url"):
        result_dict["stitched_url"] = storage_service.signed_url(
            storage_service.out_path(session_id, "stitched.jpg")
        )
    if result_dict.get("rectified_url"):
        result_dict["rectified_url"] = storage_service.signed_url(
            storage_service.out_path(session_id, "rectified.jpg")
        )
    return ProcessResult.model_validate(result_dict)


@router.get("/{session_id}", response_model=SessionState)
def get_session(session_id: str):
    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    photos = session_store.list_photos(session_id)
    # Mappiamo la riga DB nello schema SessionState atteso dal client.
    return SessionState(
        session_id=sess["id"],
        status=sess["status"],
        created_at=_iso_to_epoch(sess["created_at"]),
        updated_at=_iso_to_epoch(sess["updated_at"]),
        photos=[ARMetadata.model_validate(p["metadata"]) for p in photos],
        result=ProcessResult.model_validate(sess["result"]) if sess.get("result") else None,
    )


def _iso_to_epoch(iso: str) -> float:
    from datetime import datetime
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
