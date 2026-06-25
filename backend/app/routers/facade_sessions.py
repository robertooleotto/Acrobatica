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
    ColumnCompositeModel,
    ColumnCompositeRequest,
    ColumnCompositeResult,
    ColumnGroupModel,
    CreateSessionResponse,
    ExtrudePolygonRequest,
    ExtrudePolygonResult,
    FacadeModelRequest,
    FacadeModelResult,
    FacadePlaneModel,
    FacadePlanesResult,
    HorizontalSectionResult,
    SectionBin,
    KeystonePhotoResult,
    KeystoneSessionResult,
    MarcaturaZoneDocument,
    MeshFileInfo,
    MeshInfoResult,
    MeshUploadResult,
    ZoneMarkupResult,
    OrthorectifyPhotoResult,
    OrthorectifySessionResult,
    ProcessRequest,
    ProcessResult,
    RectifyPanoramaRequest,
    RectifyPanoramaResult,
    SessionState,
    SetScaleRequest,
    SetScaleResult,
    StripCompositeRequest,
    StripCompositeResult,
    StripPlacementModel,
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
    if result_dict.get("composite_url"):
        result_dict["composite_url"] = storage_service.signed_url(
            storage_service.out_path(session_id, "composite.jpg")
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


@router.post("/{session_id}/strip-composite", response_model=StripCompositeResult)
def create_strip_composite(session_id: str, req: StripCompositeRequest | None = None):
    """Produce il composite operativo usato dal flow principale:

    foto originali -> keystone verticale -> fasce centrali -> blending per
    traslazione. Non è una ortofoto metrica; è la base visuale su cui fare
    POST /rectify-panorama con source="composite".
    """
    from ..services.strip_composite_service import compose_vertical_strips

    req = req or StripCompositeRequest()

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    photos = sorted(session_store.list_photos(session_id), key=lambda p: int(p["order_index"]))
    if not photos:
        raise HTTPException(400, "Nessuna foto nella sessione")

    if req.order_indices:
        wanted = set(int(i) for i in req.order_indices)
        photos = [p for p in photos if int(p["order_index"]) in wanted]
        if not photos:
            raise HTTPException(400, "Nessuna foto corrisponde a order_indices")

    images: list[np.ndarray] = []
    metadata: list[dict] = []
    warnings: list[str] = []
    for p in photos:
        order = int(p["order_index"])
        try:
            raw = storage_service.download_bytes(p["storage_path"])
        except Exception as e:
            warnings.append(f"foto {order}: download fallito ({e})")
            continue
        img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            warnings.append(f"foto {order}: decode fallito")
            continue
        m = dict(p["metadata"])
        m["order_index"] = order
        images.append(img)
        metadata.append(m)

    if not images:
        raise HTTPException(400, "Nessuna foto decodificabile")

    try:
        comp = compose_vertical_strips(
            images,
            metadata,
            overlap_ratio=req.overlap_ratio,
            crop_width_ratio=req.crop_width_ratio,
            crop_height_ratio=req.crop_height_ratio,
            decompose_roll=req.decompose_roll,
            post_pitch_roll=req.post_pitch_roll,
            post_horizontal_roll=req.post_horizontal_roll,
            scale_alignment=req.scale_alignment,
            blend_mode=req.blend_mode,
        )
    except Exception as e:
        raise HTTPException(422, f"Composite fallito: {e}")

    ok, buf = cv2.imencode(".jpg", comp.composite, [cv2.IMWRITE_JPEG_QUALITY, 92])
    if not ok:
        raise HTTPException(500, "Encode composite fallito")

    safe_name = Path(req.output_name).name or "composite.jpg"
    if not safe_name.lower().endswith((".jpg", ".jpeg")):
        safe_name = f"{safe_name}.jpg"
    remote = storage_service.out_path(session_id, safe_name)
    storage_service.upload_bytes(remote, buf.tobytes(), "image/jpeg")

    # Mantieni sempre anche il nome canonico che /rectify-panorama usa con source="composite".
    if safe_name != "composite.jpg":
        storage_service.upload_bytes(storage_service.out_path(session_id, "composite.jpg"), buf.tobytes(), "image/jpeg")

    existing = sess.get("result") or {}
    existing["composite_url"] = storage_service.signed_url(storage_service.out_path(session_id, "composite.jpg"))
    existing["strip_composite"] = {
        "output_name": safe_name,
        "output_size": comp.canvas_size,
        "placements": [p.__dict__ for p in comp.placements],
        "warnings": warnings + comp.warnings,
    }
    session_store.update_session(session_id, {"result": existing})

    return StripCompositeResult(
        composite_url=storage_service.signed_url(remote, expires_in_sec=3600),
        output_size=comp.canvas_size,
        placements=[StripPlacementModel(**p.__dict__) for p in comp.placements],
        warnings=warnings + comp.warnings,
    )


@router.post("/{session_id}/column-composites", response_model=ColumnCompositeResult)
def create_column_composites(session_id: str, req: ColumnCompositeRequest | None = None):
    """Rileva le colonne/sweep e produce un composite verticale per ognuna.

    Parte sempre dalle foto originali salvate su Supabase. Ogni foto viene
    prima raddrizzata con la stessa keystone verticale già usata da Claude.
    """
    from ..services.strip_composite_service import compose_column_groups

    req = req or ColumnCompositeRequest()

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    photos = sorted(session_store.list_photos(session_id), key=lambda p: int(p["order_index"]))
    if not photos:
        raise HTTPException(400, "Nessuna foto nella sessione")

    images: list[np.ndarray] = []
    metadata: list[dict] = []
    warnings: list[str] = []
    for p in photos:
        order = int(p["order_index"])
        try:
            raw = storage_service.download_bytes(p["storage_path"])
        except Exception as e:
            warnings.append(f"foto {order}: download fallito ({e})")
            continue
        img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            warnings.append(f"foto {order}: decode fallito")
            continue
        m = dict(p["metadata"])
        m["order_index"] = order
        images.append(img)
        metadata.append(m)

    if not images:
        raise HTTPException(400, "Nessuna foto decodificabile")

    try:
        grouped = compose_column_groups(
            images,
            metadata,
            pitch_reset_deg=req.pitch_reset_deg,
            lateral_reset_m=req.lateral_reset_m,
            overlap_ratio=req.overlap_ratio,
            crop_width_ratio=req.crop_width_ratio,
            crop_height_ratio=req.crop_height_ratio,
            min_photos_per_column=req.min_photos_per_column,
            decompose_roll=req.decompose_roll,
            post_pitch_roll=req.post_pitch_roll,
            post_horizontal_roll=req.post_horizontal_roll,
            scale_alignment=req.scale_alignment,
            blend_mode=req.blend_mode,
        )
    except Exception as e:
        raise HTTPException(422, f"Composite colonne fallito: {e}")

    out_columns: list[ColumnCompositeModel] = []
    for col in grouped.columns:
        ok, buf = cv2.imencode(".jpg", col.composite, [cv2.IMWRITE_JPEG_QUALITY, 92])
        if not ok:
            warnings.append(f"colonna {col.column_index}: encode fallito")
            continue
        remote = storage_service.out_path(session_id, f"column_{col.column_index:02d}_composite.jpg")
        storage_service.upload_bytes(remote, buf.tobytes(), "image/jpeg")
        out_columns.append(ColumnCompositeModel(
            column_index=col.column_index,
            order_indices=col.order_indices,
            composite_url=storage_service.signed_url(remote, expires_in_sec=3600),
            output_size=col.canvas_size,
            placements=[StripPlacementModel(**p.__dict__) for p in col.placements],
            warnings=col.warnings,
        ))

    existing = sess.get("result") or {}
    existing["column_composites"] = {
        "groups": [g.__dict__ for g in grouped.groups],
        "columns": [
            {
                "column_index": c.column_index,
                "order_indices": c.order_indices,
                "output_size": c.output_size,
                "placements": [p.model_dump() for p in c.placements],
                "warnings": c.warnings,
            }
            for c in out_columns
        ],
        "warnings": warnings + grouped.warnings,
    }
    session_store.update_session(session_id, {"result": existing})

    return ColumnCompositeResult(
        columns=out_columns,
        groups=[ColumnGroupModel(**g.__dict__) for g in grouped.groups],
        warnings=warnings + grouped.warnings,
    )


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


@router.get("/{session_id}/planes", response_model=FacadePlanesResult)
def detect_session_planes(session_id: str, step: int = 1, max_planes: int = 5):
    """Rileva AUTOMATICAMENTE i piani di facciata della sessione (sostituisce
    il flusso manuale 4-tap): triangolazione fotografica dalle pose ARKit +
    RANSAC multi-piano di piani quasi verticali, con filtro muro-fantasma
    (riflessi nei vetri) e dedup. Il primo piano per n_inliers è la facciata
    principale.

    Operazione pesante (SIFT su tutte le foto): minuti, non secondi. `step`
    usa una foto ogni `step` per un risultato più rapido/grossolano.
    """
    from ..services.facade_planes import detect_facade_planes

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    photos = sorted(session_store.list_photos(session_id), key=lambda p: int(p["order_index"]))
    if len(photos) < 2:
        raise HTTPException(400, "Servono almeno 2 foto con posa ARKit")

    warnings: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        entries: list[dict] = []
        for p in photos:
            order = int(p["order_index"])
            try:
                raw = storage_service.download_bytes(p["storage_path"])
            except Exception as e:
                warnings.append(f"foto {order}: download fallito ({e})")
                continue
            local = td_path / Path(p["storage_path"]).name
            local.write_bytes(raw)
            entries.append({
                "storage_path": p["storage_path"],
                "local_path": str(local),
                "metadata": p["metadata"],
            })
        if len(entries) < 2:
            raise HTTPException(400, "Nessuna foto scaricabile per la triangolazione")
        try:
            res, cloud = detect_facade_planes(td_path, entries, step=step,
                                              max_planes=max_planes, return_cloud=True)
        except Exception as e:
            raise HTTPException(422, f"Rilevamento piani fallito: {e}")

    # Persisti la nuvola su storage: serve a /zone-proposals senza ritriangolare.
    try:
        import io
        buf_npz = io.BytesIO()
        np.savez_compressed(buf_npz, points=cloud.points, n_obs=cloud.n_obs,
                            rms=cloud.rms_px, camera_centers=cloud.camera_centers)
        storage_service.upload_bytes(
            storage_service.out_path(session_id, "cloud.npz"),
            buf_npz.getvalue(), "application/octet-stream")
    except Exception as e:
        warnings.append(f"salvataggio nuvola fallito ({e}): /zone-proposals non disponibile")

    if not res["planes"]:
        warnings.append("Nessun piano quasi-verticale trovato: nuvola troppo povera?")

    # Persisti in result.facade_planes per riuso (es. /orthorectify automatico).
    existing = sess.get("result") or {}
    existing["facade_planes"] = res
    session_store.update_session(session_id, {"result": existing})

    return FacadePlanesResult(
        planes=[FacadePlaneModel(**pl) for pl in res["planes"]],
        stats=res["stats"],
        warnings=warnings,
    )


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


# ─── Rettifica facciata 2D via 4-tap (NUOVO FLOW PRINCIPALE) ────────────────

@router.post("/{session_id}/rectify-panorama", response_model=RectifyPanoramaResult)
def rectify_panorama(session_id: str, req: RectifyPanoramaRequest):
    """Rettifica la facciata via 4-tap homography 2D sul panorama esistente.

    Più robusta del fit 3D triangolato (vedi discussione 2026-05-22): non
    dipende da ARKit pose, non ha problemi con elementi rientranti come
    porte/vetrine. L'utente è responsabile di scegliere 4 punti sul muro
    principale.
    """
    from ..services.rectify_facade import rectify_quad_to_rect, validate_quad

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")

    # Carica il panorama dalla sorgente scelta
    src_name = "stitched.jpg" if req.source == "stitched" else "composite.jpg"
    src_path = storage_service.out_path(session_id, src_name)
    try:
        raw = storage_service.download_bytes(src_path)
    except Exception as e:
        raise HTTPException(409, f"Sorgente '{src_name}' non trovata: chiama prima /process o /orthorectify. ({e})")
    img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise HTTPException(500, "Decode sorgente fallito")

    H_img, W_img = img.shape[:2]
    err = validate_quad(req.src_quad, W_img, H_img)
    if err:
        raise HTTPException(400, f"Validazione 4-tap fallita: {err}")

    rectified, info = rectify_quad_to_rect(img, req.src_quad,
                                            output_max_dim=req.output_max_dim)
    ok, buf = cv2.imencode(".jpg", rectified, [cv2.IMWRITE_JPEG_QUALITY, 92])
    if not ok:
        raise HTTPException(500, "Encode rettificato fallito")
    out_path = storage_service.out_path(session_id, "rectified_facade.jpg")
    storage_service.upload_bytes(out_path, buf.tobytes(), "image/jpeg")
    return RectifyPanoramaResult(
        rectified_url=storage_service.signed_url(out_path, expires_in_sec=3600),
        output_size=info.output_size,
        homography_3x3=info.homography_3x3,
    )


# ─── Mesh 3D (Object Capture dal Mac → backend → iPad) ──────────────────────

_MESH_CONTENT_TYPES = {
    ".obj": "model/obj",
    ".mtl": "model/mtl",
    ".usdz": "model/vnd.usdz+zip",
    ".ply": "application/octet-stream",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
}


def _mesh_remote(session_id: str, name: str) -> str:
    # Sotto-cartella dedicata, nome sanificato (niente path traversal).
    return storage_service.out_path(session_id, f"mesh/{Path(name).name}")


@router.put("/{session_id}/mesh", response_model=MeshUploadResult)
async def upload_mesh(session_id: str, files: list[UploadFile] = File(...)):
    """Riceve la mesh di Object Capture dal Mac (OBJ + eventuali MTL/PNG texture).

    PUT idempotente: sovrascrive i file con lo stesso nome. Il primo .obj
    caricato diventa la mesh principale servita all'app. Lo script Mac da
    `backend/photogrammetry/objectcapture/` farà questa POST dopo usdz2obj.
    """
    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    if not files:
        raise HTTPException(400, "Nessun file mesh caricato")

    infos: list[MeshFileInfo] = []
    manifest: list[dict] = []
    main_obj: str | None = None
    for f in files:
        name = Path(f.filename or "mesh").name
        ext = Path(name).suffix.lower()
        if ext not in _MESH_CONTENT_TYPES:
            raise HTTPException(400, f"Estensione mesh non supportata: '{name}'")
        data = await f.read()
        remote = _mesh_remote(session_id, name)
        storage_service.upload_bytes(remote, data, _MESH_CONTENT_TYPES[ext])
        manifest.append({"name": name, "size": len(data)})
        if ext == ".obj" and main_obj is None:
            main_obj = name
        infos.append(MeshFileInfo(
            name=name,
            url=storage_service.signed_url(remote, expires_in_sec=3600),
            size_bytes=len(data),
        ))

    existing = sess.get("result") or {}
    existing["mesh"] = {"files": manifest, "main_obj": main_obj}
    session_store.update_session(session_id, {"result": existing})

    return MeshUploadResult(session_id=session_id, files=infos)


@router.get("/{session_id}/mesh", response_model=MeshInfoResult)
def get_mesh(session_id: str):
    """Restituisce gli URL firmati della mesh per il download su iPad."""
    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    mesh = (sess.get("result") or {}).get("mesh")
    if not mesh or not mesh.get("files"):
        raise HTTPException(404, "Nessuna mesh caricata per questa sessione")

    files: list[MeshFileInfo] = []
    main: MeshFileInfo | None = None
    for entry in mesh["files"]:
        name = entry["name"] if isinstance(entry, dict) else entry
        size = int(entry.get("size", 0)) if isinstance(entry, dict) else 0
        remote = _mesh_remote(session_id, name)
        info = MeshFileInfo(
            name=name,
            url=storage_service.signed_url(remote, expires_in_sec=3600),
            size_bytes=size,
        )
        files.append(info)
        if name == mesh.get("main_obj"):
            main = info
    return MeshInfoResult(session_id=session_id, main_obj=main, files=files)


# ─── Pre-marcatura automatica: zone fuori-piano proposte ────────────────────

@router.get("/{session_id}/zone-proposals", response_model=MarcaturaZoneDocument)
def get_zone_proposals(
    session_id: str,
    ppm: float = 110.0,
    soglia_m: float = 0.15,
    solo_sporgenze: bool = True,
):
    """Propone zone "Esclusa" dai punti fuori-piano (balconi, aggetti > soglia).

    Prerequisito: GET /planes già eseguito (salva nuvola `out/cloud.npz` e
    piani in `result.facade_planes`). Le coordinate pixel sono nello spazio
    dell'ortofoto derivata dal piano principale (convenzione v22: origine in
    alto a sinistra, x=(u−u_min)·ppm, y=(v_max−v)·ppm) — l'editor iOS deve
    verificarle contro le dimensioni dell'immagine che mostra.
    """
    import io
    from ..services.zone_proposals import proponi_zone

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    res = sess.get("result") or {}
    fp = res.get("facade_planes") or {}
    planes = fp.get("planes") or []
    if not planes:
        raise HTTPException(409, "Nessun piano rilevato: chiama prima GET /planes")
    try:
        raw = storage_service.download_bytes(storage_service.out_path(session_id, "cloud.npz"))
    except Exception:
        raise HTTPException(409, "Nuvola non trovata: riesegui GET /planes (la salva su storage)")
    npz = np.load(io.BytesIO(raw))
    points = npz["points"]

    try:
        return proponi_zone(points, planes[0], ppm=ppm, soglia_m=soglia_m,
                            solo_sporgenze=solo_sporgenze)
    except ValueError as e:
        raise HTTPException(400, str(e))


# ─── Geometria 3D semi-automatica (estrusione poligoni utente) ──────────────
# Filosofia: la nuvola fotografica è rada → l'utente disegna i poligoni delle
# regioni (torretta, loggia, nicchia) sull'ortofoto; il backend campiona la
# nuvola dentro ogni poligono e ne ricava la PROFONDITÀ robusta. Geometria
# 100% fotografica: niente mesh/Object Capture/Umeyama.

def _load_session_cloud(session_id: str) -> np.ndarray:
    """Carica la nuvola `out/cloud.npz` salvata da GET /planes, o 409."""
    import io
    try:
        raw = storage_service.download_bytes(
            storage_service.out_path(session_id, "cloud.npz"))
    except Exception:
        raise HTTPException(409, "Nuvola non trovata: esegui prima /planes")
    return np.load(io.BytesIO(raw))["points"]


def _main_plane(sess: dict) -> dict:
    """Piano principale (più popolato) salvato in result.facade_planes, o 409."""
    res = sess.get("result") or {}
    planes = (res.get("facade_planes") or {}).get("planes") or []
    if not planes:
        raise HTTPException(409, "Nessun piano rilevato: esegui prima /planes")
    return planes[0]


@router.post("/{session_id}/extrude", response_model=ExtrudePolygonResult)
def extrude_polygon_endpoint(session_id: str, req: ExtrudePolygonRequest):
    """Profondità robusta della regione racchiusa dal poligono disegnato.

    Campiona la nuvola (out/cloud.npz, salvata da /planes) dentro il poligono
    e stima la profondità w con mediana + MAD, scartando outlier (riflessi nei
    vetri). Se i punti sono troppo pochi ritorna needs_user_depth=True.
    """
    from ..services.facade_geometry import extrude_polygon

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    plane = _main_plane(sess)
    points = _load_session_cloud(session_id)
    try:
        out = extrude_polygon(req.poly_px, points, plane, ppm=req.ppm)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return ExtrudePolygonResult(**out)


@router.get("/{session_id}/section", response_model=HorizontalSectionResult)
def horizontal_section_endpoint(
    session_id: str,
    quota: float,
    band: float = 0.5,
):
    """Profilo orizzontale (u, w mediano) di una fascia di quota [quota±band/2].

    Strumento di supporto per l'editor: mostra dove il muro avanza (torretta) o
    rientra (loggia) lungo l'asse orizzontale del piano. `quota` e `band` sono
    in metri lungo l'asse up del piano, rispetto al centro `c`.
    """
    from ..services.facade_geometry import horizontal_section

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    plane = _main_plane(sess)
    points = _load_session_cloud(session_id)
    try:
        profilo = horizontal_section(points, plane, v_quota=quota, band=band)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return HorizontalSectionResult(
        v_quota_m=quota, band_m=band,
        profilo=[SectionBin(**b) for b in profilo],
    )


@router.post("/{session_id}/facade-model", response_model=FacadeModelResult)
def build_facade_model_endpoint(session_id: str, req: FacadeModelRequest):
    """Costruisce il modello a scatole (piano + prismi estrusi con spallette).

    Salva out/facade_model.json + out/facade_model.obj su storage e ritorna il
    JSON editabile + gli URL. Il piano principale viene letto da
    result.facade_planes (esegui prima /planes).
    """
    from ..services.facade_geometry import build_facade_model

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    plane = _main_plane(sess)

    prisms = [p.model_dump() for p in req.prisms]
    try:
        built = build_facade_model(plane, prisms, ppm=req.ppm)
    except ValueError as e:
        raise HTTPException(400, str(e))

    model_json = built["model_json"]
    obj_text = built["obj_text"]

    model_url = obj_url = None
    try:
        json_remote = storage_service.out_path(session_id, "facade_model.json")
        storage_service.upload_bytes(
            json_remote,
            json.dumps(model_json, ensure_ascii=False, indent=2).encode("utf-8"),
            "application/json")
        obj_remote = storage_service.out_path(session_id, "facade_model.obj")
        storage_service.upload_bytes(obj_remote, obj_text.encode("utf-8"),
                                     "text/plain")
        model_url = storage_service.signed_url(json_remote, expires_in_sec=3600)
        obj_url = storage_service.signed_url(obj_remote, expires_in_sec=3600)
    except Exception:
        pass  # in assenza di storage ritorniamo comunque il JSON inline

    existing = sess.get("result") or {}
    existing["facade_model"] = {
        "n_vertices": model_json["n_vertices"],
        "n_faces": model_json["n_faces"],
        "n_prisms": len(model_json["prisms"]),
    }
    session_store.update_session(session_id, {"result": existing})

    return FacadeModelResult(
        n_vertices=model_json["n_vertices"],
        n_faces=model_json["n_faces"],
        n_prisms=len(model_json["prisms"]),
        model_json=model_json,
        model_url=model_url,
        obj_url=obj_url,
    )


# ─── Marcatura zone (upload dall'editor iOS) ────────────────────────────────

@router.put("/{session_id}/zone-markup", response_model=ZoneMarkupResult)
def upload_zone_markup(session_id: str, doc: MarcaturaZoneDocument):
    """Riceve il documento di marcatura zone dall'editor iOS, ricalcola le
    metriche server-side (punti_px + ppm sono la fonte di verità), salva il
    JSON su storage e i totali in `result.zone_markup`.

    PUT idempotente: ogni upload sostituisce la marcatura precedente della
    sessione (l'editor salva l'intero documento, non i delta).
    """
    from ..services import zone_markup

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")

    errori = zone_markup.valida_documento(doc)
    if errori:
        raise HTTPException(422, "Marcatura non valida: " + "; ".join(errori))

    warnings = zone_markup.ricalcola_metriche(doc)
    aree, lunghezze = zone_markup.totali_per_tipo(doc.zone)

    payload = json.dumps(doc.model_dump(), ensure_ascii=False, indent=2).encode("utf-8")
    remote = storage_service.out_path(session_id, "zone_markup.json")
    storage_service.upload_bytes(remote, payload, "application/json")

    existing = sess.get("result") or {}
    existing["zone_markup"] = {
        "zone_count": len(doc.zone),
        "ppm": doc.ppm,
        "area_m2_per_tipo": aree,
        "lunghezza_m_per_tipo": lunghezze,
        "storage_path": remote,
    }
    session_store.update_session(session_id, {"result": existing})

    return ZoneMarkupResult(
        session_id=session_id,
        zone_count=len(doc.zone),
        area_m2_per_tipo=aree,
        lunghezza_m_per_tipo=lunghezze,
        markup_url=storage_service.signed_url(remote, expires_in_sec=3600),
        warnings=warnings,
    )


@router.get("/{session_id}/zone-markup", response_model=MarcaturaZoneDocument)
def get_zone_markup(session_id: str):
    """Restituisce l'ultimo documento di marcatura salvato per la sessione."""
    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")
    remote = storage_service.out_path(session_id, "zone_markup.json")
    try:
        raw = storage_service.download_bytes(remote)
    except Exception:
        raise HTTPException(404, "Nessuna marcatura salvata per questa sessione")
    return MarcaturaZoneDocument.model_validate_json(raw)


# ─── Scala metrica (2 tap + distanza nota sul rectified_facade) ─────────────

@router.post("/{session_id}/scale", response_model=SetScaleResult)
def set_scale(session_id: str, req: SetScaleRequest):
    """Calcola e salva meters/pixel dato 2 tap utente + distanza reale.

    Aspettativa: i 2 tap sono in pixel del rectified_facade.jpg (non del
    panorama originale). L'utente sa esattamente la distanza fisica fra i
    2 punti (es. larghezza di una finestra nota, altezza di una porta nota).
    """
    from ..services.rectify_facade import meters_per_pixel

    sess = session_store.get_session(session_id)
    if sess is None:
        raise HTTPException(404, "Sessione non trovata")

    try:
        mpp = meters_per_pixel(req.p1, req.p2, req.distance_m)
    except ValueError as e:
        raise HTTPException(400, str(e))

    # Recupera dimensioni del rettificato per calcolare width/height in metri
    fw_m = fh_m = None
    try:
        raw = storage_service.download_bytes(storage_service.out_path(session_id, "rectified_facade.jpg"))
        img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
        if img is not None:
            fh_m = float(img.shape[0] * mpp)
            fw_m = float(img.shape[1] * mpp)
    except Exception:
        pass  # se rettificato non esiste ancora, ritorniamo solo mpp

    # Persisti in session.result (jsonb) per consultazioni successive
    existing = sess.get("result") or {}
    existing["scale_meters_per_pixel"] = mpp
    if fw_m is not None: existing["facade_width_m"] = fw_m
    if fh_m is not None: existing["facade_height_m"] = fh_m
    session_store.update_session(session_id, {"result": existing})

    return SetScaleResult(
        meters_per_pixel=mpp, facade_width_m=fw_m, facade_height_m=fh_m,
    )
