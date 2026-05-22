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
    KeystonePhotoResult,
    KeystoneSessionResult,
    OrthorectifyPhotoResult,
    OrthorectifySessionResult,
    ProcessRequest,
    ProcessResult,
    SessionState,
    TriangulateRequest,
    TriangulateResult,
    UploadPhotoResponse,
    WallPlaneModel,
)
from ..services import (
    measurement_service,
    rectification_service,
    segmentation_service,
    session_store,
    storage_service,
    stitching_service,
    triangulation_service,
)
from ..services.triangulation_service import CameraPose, Point3D

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


@router.post("/{session_id}/keystone", response_model=KeystoneSessionResult)
def keystone_session(session_id: str):
    """Applica keystone correction (rotation-only homography) a ogni foto della
    sessione, usando pitch/roll dai metadati ARKit. Salva le foto raddrizzate
    su Supabase Storage e restituisce gli URL signed.

    Le linee verticali del muro tornano parallele. Non corregge proporzioni
    (Step 3 successivo) né cuce le foto (Step 4).
    """
    import io
    import tempfile
    import cv2
    import numpy as np
    from ..services.keystone_correction import keystone_correct

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    photos = session_store.list_photos(session_id)
    if not photos:
        raise HTTPException(400, "Nessuna foto nella sessione")

    out: list[KeystonePhotoResult] = []
    warnings: list[str] = []

    # Una sola normale del muro per tutta la sessione: media (normalizzata) di
    # quelle che le foto ci hanno mandato. Robusto al rumore delle stime
    # `.estimatedPlane` di ARKit su facciate lontane. Allineiamo i segni prima
    # di sommare (una normale può venirci col verso opposto).
    session_wall_normal: list[float] | None = None
    normals_raw: list[list[float]] = []
    for p in photos:
        n = p["metadata"].get("wall_normal_world")
        if n and len(n) == 3:
            normals_raw.append([float(n[0]), float(n[1]), float(n[2])])
    if normals_raw:
        ref = np.array(normals_raw[0], dtype=np.float64)
        acc = np.zeros(3, dtype=np.float64)
        for v in normals_raw:
            a = np.array(v, dtype=np.float64)
            if float(np.dot(a, ref)) < 0:
                a = -a
            acc += a
        nn = float(np.linalg.norm(acc))
        if nn > 1e-6:
            avg = acc / nn
            session_wall_normal = [float(avg[0]), float(avg[1]), float(avg[2])]
            warnings.append(
                f"wall_normal_world: media su {len(normals_raw)}/{len(photos)} foto"
            )

    for p in photos:
        m = p["metadata"]
        order = p["order_index"]
        storage_path = p["storage_path"]
        # Scarica la foto originale.
        try:
            raw = storage_service.download_bytes(storage_path)
        except Exception as e:
            warnings.append(f"foto {order}: download fallito ({e})")
            continue
        arr = np.frombuffer(raw, dtype=np.uint8)
        img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if img is None:
            warnings.append(f"foto {order}: decode fallito")
            continue
        intrinsics = m["camera_intrinsics"]
        cam_transform = m.get("camera_transform")
        if cam_transform is None:
            warnings.append(f"foto {order}: manca camera_transform")
            continue
        meta_size = (int(m["image_width"]), int(m["image_height"]))
        # Preferisci la normale media di sessione (più stabile); fallback per-foto.
        wall_n = session_wall_normal if session_wall_normal is not None else m.get("wall_normal_world")
        try:
            rectified, info = keystone_correct(
                img, intrinsics,
                camera_transform=cam_transform,
                wall_normal_world=wall_n,
                metadata_image_size=meta_size,
            )
        except Exception as e:
            warnings.append(f"foto {order}: keystone fallito ({e})")
            continue
        # eulers solo per il response (back-compat con KeystonePhotoResult).
        euler = m.get("euler_angles") or [0.0, 0.0, 0.0]
        # Encode + upload come photo_<order>_keystone.jpg
        ok, buf = cv2.imencode(".jpg", rectified, [cv2.IMWRITE_JPEG_QUALITY, 88])
        if not ok:
            warnings.append(f"foto {order}: encode fallito")
            continue
        rect_path = f"sessions/{session_id}/out/photo_{order:04d}_keystone.jpg"
        try:
            storage_service.upload_bytes(rect_path, buf.tobytes(), "image/jpeg")
            rect_url = storage_service.signed_url(rect_path, expires_in_sec=3600)
            orig_url = storage_service.signed_url(storage_path, expires_in_sec=3600)
        except Exception as e:
            warnings.append(f"foto {order}: upload fallito ({e})")
            continue
        out.append(KeystonePhotoResult(
            order_index=order,
            original_url=orig_url,
            rectified_url=rect_url,
            pitch_deg=float(euler[0]),
            roll_deg=float(euler[2]),
            yaw_deg=float(euler[1]),
            input_size=info.input_size,
            output_size=info.output_size,
        ))

    return KeystoneSessionResult(photos=out, warnings=warnings)


@router.post("/{session_id}/triangulate", response_model=TriangulateResult)
def triangulate_corners(session_id: str, req: TriangulateRequest):
    """Riceve 4 angoli, ognuno con >=2 tap su foto diverse, triangola in 3D e
    restituisce m² + larghezza/altezza usando le pose ARKit salvate."""
    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    photos = session_store.list_photos(session_id)
    if not photos:
        raise HTTPException(400, "Nessuna foto nella sessione")

    # Mappa order_index → metadata della foto.
    meta_by_idx: dict[int, dict] = {p["order_index"]: p["metadata"] for p in photos}

    def pose_for(idx: int) -> CameraPose:
        m = meta_by_idx.get(idx)
        if m is None:
            raise HTTPException(400, f"order_index {idx} non trovato in sessione")
        return CameraPose(
            transform=tuple(m["camera_transform"]),
            intrinsics=tuple(m["camera_intrinsics"]),
        )

    corners_3d: list[Point3D] = []
    warnings: list[str] = []
    for i, taps in enumerate(req.corners):
        if len(taps) < 2:
            raise HTTPException(400, f"Angolo {i+1}: servono almeno 2 tap su foto diverse")
        rays = []
        for t in taps:
            pose = pose_for(t.photo_order_index)
            rays.append(triangulation_service.ray_from_pixel(pose, t.pixel[0], t.pixel[1]))
        p3 = triangulation_service.triangulate_rays(rays)
        if p3 is None:
            raise HTTPException(422, f"Angolo {i+1}: triangolazione fallita (raggi paralleli?)")
        corners_3d.append(p3)

    width, height = triangulation_service.quad_dimensions(corners_3d)
    area = triangulation_service.polygon_area_3d(corners_3d)
    return TriangulateResult(
        corners_3d=[(p.x, p.y, p.z) for p in corners_3d],
        width_m=width,
        height_m=height,
        area_m2=area,
        warnings=warnings,
    )


@router.post("/{session_id}/wall-plane", response_model=WallPlaneModel)
def compute_wall_plane(session_id: str, req: TriangulateRequest):
    """Triangola i 4 angoli del muro dai tap utente, fitta il piano via SVD, lo
    salva nel record sessione (campo `result.wall_plane`) e lo ritorna.

    Riusa il flusso `triangulate_corners` per i raggi, poi `fit_plane_from_points`
    per ottenere il piano 3D completo (normale + assi right/up + bounds 2D).
    """
    from ..services.orthorectify_service import fit_plane_from_points

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    photos = session_store.list_photos(session_id)
    if not photos:
        raise HTTPException(400, "Nessuna foto nella sessione")
    meta_by_idx: dict[int, dict] = {p["order_index"]: p["metadata"] for p in photos}

    corners_3d: list[Point3D] = []
    for i, taps in enumerate(req.corners):
        if len(taps) < 2:
            raise HTTPException(400, f"Angolo {i+1}: servono almeno 2 tap su foto diverse")
        rays = []
        for t in taps:
            m = meta_by_idx.get(t.photo_order_index)
            if m is None:
                raise HTTPException(400, f"order_index {t.photo_order_index} non trovato")
            pose = CameraPose(transform=tuple(m["camera_transform"]),
                              intrinsics=tuple(m["camera_intrinsics"]))
            rays.append(triangulation_service.ray_from_pixel(pose, t.pixel[0], t.pixel[1]))
        p3 = triangulation_service.triangulate_rays(rays)
        if p3 is None:
            raise HTTPException(422, f"Angolo {i+1}: triangolazione fallita")
        corners_3d.append(p3)

    pts = [(p.x, p.y, p.z) for p in corners_3d]
    try:
        plane = fit_plane_from_points(pts)
    except ValueError as e:
        raise HTTPException(422, f"Fit piano fallito: {e}")

    # Persisti in `result.wall_plane` per essere riusato da /orthorectify.
    existing = sess.get("result") or {}
    existing["wall_plane"] = plane.to_dict()
    session_store.update_session(session_id, {"result": existing})

    return WallPlaneModel(**plane.to_dict())


@router.post("/{session_id}/orthorectify", response_model=OrthorectifySessionResult)
def orthorectify_session(session_id: str, pixels_per_meter: float = 200):
    """Applica orthorectification a ogni foto della sessione usando il piano del
    muro salvato (chiamare prima POST /wall-plane). Produce N immagini ortografiche
    + opzionalmente un composite finale.
    """
    import cv2 as _cv2
    import numpy as _np
    from ..services.orthorectify_service import (
        WallPlane, orthorectify_photo, composite_orthos,
    )

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    res = sess.get("result") or {}
    wp_dict = res.get("wall_plane")
    if not wp_dict:
        raise HTTPException(409, "Wall plane non calcolato. Chiama prima POST /wall-plane.")
    plane = WallPlane.from_dict(wp_dict)

    photos = session_store.list_photos(session_id)
    if not photos:
        raise HTTPException(400, "Nessuna foto nella sessione")

    out: list[OrthorectifyPhotoResult] = []
    warnings: list[str] = []
    orthos_for_composite: list[_np.ndarray] = []

    for p in photos:
        m = p["metadata"]
        order = p["order_index"]
        try:
            raw = storage_service.download_bytes(p["storage_path"])
        except Exception as e:
            warnings.append(f"foto {order}: download fallito ({e})"); continue
        img = _cv2.imdecode(_np.frombuffer(raw, dtype=_np.uint8), _cv2.IMREAD_COLOR)
        if img is None:
            warnings.append(f"foto {order}: decode fallito"); continue
        try:
            ortho, info = orthorectify_photo(
                img,
                intrinsics=m["camera_intrinsics"],
                camera_transform=m["camera_transform"],
                plane=plane,
                pixels_per_meter=pixels_per_meter,
                metadata_image_size=(int(m["image_width"]), int(m["image_height"])),
            )
        except Exception as e:
            warnings.append(f"foto {order}: ortho fallito ({e})"); continue
        ok, buf = _cv2.imencode(".jpg", ortho, [_cv2.IMWRITE_JPEG_QUALITY, 88])
        if not ok:
            warnings.append(f"foto {order}: encode fallito"); continue
        remote = f"sessions/{session_id}/out/photo_{order:04d}_ortho.jpg"
        try:
            storage_service.upload_bytes(remote, buf.tobytes(), "image/jpeg")
            url = storage_service.signed_url(remote, expires_in_sec=3600)
        except Exception as e:
            warnings.append(f"foto {order}: upload fallito ({e})"); continue
        orthos_for_composite.append(ortho)
        out.append(OrthorectifyPhotoResult(
            order_index=order,
            ortho_url=url,
            pre_rotated_cw=info.pre_rotated_cw,
            output_size=info.output_size,
            pixels_per_meter=info.pixels_per_meter,
        ))

    composite_url = None
    if len(orthos_for_composite) >= 2:
        try:
            comp = composite_orthos(orthos_for_composite)
            ok, buf = _cv2.imencode(".jpg", comp, [_cv2.IMWRITE_JPEG_QUALITY, 90])
            if ok:
                remote = storage_service.out_path(session_id, "ortho_composite.jpg")
                storage_service.upload_bytes(remote, buf.tobytes(), "image/jpeg")
                composite_url = storage_service.signed_url(remote, expires_in_sec=3600)
        except Exception as e:
            warnings.append(f"composite fallito ({e})")

    return OrthorectifySessionResult(
        wall_plane=WallPlaneModel(**plane.to_dict()),
        photos=out, composite_url=composite_url, warnings=warnings,
    )


def _iso_to_epoch(iso: str) -> float:
    from datetime import datetime
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
