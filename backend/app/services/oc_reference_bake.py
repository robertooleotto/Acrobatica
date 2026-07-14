"""Bake dei piani usando la texture Object Capture come atlante metrico.

Le pose OC forniscono la proiezione iniziale. Ogni foto viene poi registrata con
una piccola trasformazione residua contro il bake OC e, infine, tutte le foto
accettate vengono ottimizzate insieme sulle loro sovrapposizioni. Il compositing
mantiene una sola sorgente dominante e sfuma soltanto una fascia stretta sui
bordi, evitando la perdita di nitidezza del blending medio.
"""
from __future__ import annotations

import gc
import json
import os
from pathlib import Path

import cv2
import numpy as np

from . import ortho_bake as ob
from scripts import run_oc_reference_registration_local as registration
from scripts.oc_compositing import coverage_rgba, mosaic


def _identity_correction() -> dict[str, object]:
    return {
        "offset_x": 0.0,
        "offset_y": 0.0,
        "rotation_deg": 0.0,
        "scale": 1.0,
        "matrix": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    }


def _compose_plane(
    textured_mesh: registration.TexturedMesh,
    pf: ob.PlaneFrame,
    plane: dict,
    cams: list[ob.Camera],
    photo_resolver,
    *,
    scale_m_per_mesh_unit: float,
    max_photos: int,
    coverage_photos: int,
    crop: float,
    depth_m: float,
    max_residual_px: float,
    max_rotation_deg: float,
    max_scale_error: float,
) -> tuple[np.ndarray, float, list[str], dict]:
    normal = registration.orient_normal(
        np.asarray(plane["normale"], float), pf.corners.mean(0), cams,
    )
    horizontal_flipped = registration.orient_frame_for_front_view(pf, normal)
    reference_rgba, reference_mask, depth = registration.render_oc_reference(
        textured_mesh, pf, normal, depth_m, scale_m_per_mesh_unit,
    )
    reference = reference_rgba[..., :3]
    planar_reference = reference_mask & np.isfinite(depth) & (np.abs(depth) <= 0.35)

    sift = cv2.SIFT_create(nfeatures=5000, contrastThreshold=0.025, edgeThreshold=12)
    reference_points, reference_descriptors = sift.detectAndCompute(
        registration._normalized_gray(reference),
        planar_reference.astype(np.uint8) * 255,
    )
    ranked = registration.rank_candidates(pf, normal, cams, crop=crop)
    camera_by_key = {str(int(cam.key)): cam for cam in cams}

    accepted_images: list[np.ndarray] = []
    accepted_planar_masks: list[np.ndarray] = []
    accepted_full_masks: list[np.ndarray] = []
    accepted_keys: list[str] = []
    photo_reports: list[dict[str, object]] = []

    for rank, candidate in enumerate(ranked[:max_photos], 1):
        key = str(candidate["key"])
        resolved = photo_resolver(key)
        item: dict[str, object] = {
            "rank": rank, **candidate, "photo_found": bool(resolved),
        }
        if not resolved:
            photo_reports.append(item)
            continue
        posed, posed_mask = registration.warp_photo_to_plane(
            Path(resolved), camera_by_key[key], pf,
        )
        aligned, aligned_mask, residual = registration.register_residual(
            reference, planar_reference, reference_points, reference_descriptors,
            posed, posed_mask,
            max_rotation_deg=max_rotation_deg,
            max_scale_error=max_scale_error,
            max_residual_px=max_residual_px,
        )
        item["registration"] = residual
        photo_reports.append(item)
        if bool(residual.get("accepted")):
            accepted_images.append(aligned)
            accepted_planar_masks.append(aligned_mask & planar_reference)
            accepted_full_masks.append(aligned_mask)
            accepted_keys.append(key)

    accepted_images, accepted_planar_masks, global_report, corrections = \
        registration.global_align_photos(
            accepted_images, accepted_planar_masks, accepted_keys,
        )
    size = (pf.tex_w, pf.tex_h)
    compositing_masks = [
        cv2.warpAffine(
            mask.astype(np.uint8), np.asarray(correction["matrix"], np.float64),
            size, flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT,
        ) > 0
        for mask, correction in zip(accepted_full_masks, corrections)
    ]
    for key, correction in zip(accepted_keys, corrections):
        for item in photo_reports:
            if str(item.get("key")) == key and isinstance(item.get("registration"), dict):
                item["registration"]["global_correction"] = correction
                break

    covered = np.zeros((pf.tex_h, pf.tex_w), bool)
    for mask in compositing_masks:
        covered |= mask

    # Se il riferimento OC non ha feature sufficienti, conserva comunque il
    # risultato metrico delle pose invece di produrre una texture vuota.
    filler_start = max_photos if accepted_images else 0
    filler_limit = max(max_photos, coverage_photos)
    for rank, candidate in enumerate(ranked[filler_start:filler_limit], filler_start + 1):
        key = str(candidate["key"])
        if key in accepted_keys:
            continue
        resolved = photo_resolver(key)
        if not resolved:
            continue
        posed, posed_mask = registration.warp_photo_to_plane(
            Path(resolved), camera_by_key[key], pf,
        )
        new_pixels = posed_mask & ~covered
        if int(new_pixels.sum()) < 200:
            continue
        accepted_images.append(posed)
        compositing_masks.append(posed_mask)
        accepted_keys.append(key)
        photo_reports.append({
            "rank": rank, **candidate, "photo_found": True,
            "registration": {
                "accepted": True,
                "reason": "riempimento copertura da posa",
                "pose_only_filler": True,
                "global_correction": _identity_correction(),
            },
        })
        covered |= posed_mask

    rgba = coverage_rgba(mosaic(accepted_images, compositing_masks, reference),
                         compositing_masks)
    polygon = ob._polygon_mask(pf.tex_w, pf.tex_h, pf.polygon_uv)
    coverage = float(covered[polygon].mean()) if polygon.any() else 0.0
    report = {
        "horizontal_flipped_for_front_view": horizontal_flipped,
        "oc_reference_coverage": round(float(reference_mask[polygon].mean()), 4)
        if polygon.any() else 0.0,
        "planar_reference_coverage": round(float(planar_reference[polygon].mean()), 4)
        if polygon.any() else 0.0,
        "accepted_photos": len(accepted_images),
        "registered_photos": len(corrections),
        "global_alignment": global_report,
        "photos": photo_reports,
    }
    return rgba, coverage, accepted_keys, report


def bake_planes(
    clean_mesh_path: str,
    raw_obj_path: str,
    raw_mtl_path: str,
    poses: dict,
    photos_dir: str,
    planes_doc: dict,
    out_dir: str,
    *,
    texel_mm: float = 20.0,
    max_photos: int = 20,
    coverage_photos: int = 60,
    crop: float = 0.9,
    scale_m_per_mesh_unit: float = 1.0,
    photo_resolver=None,
    progress=None,
    log=print,
) -> dict:
    """Bake sequenziale di tutti i piani con riferimento OC testurizzato."""
    if photo_resolver is None:
        photo_resolver = lambda key: ob.photo_path(photos_dir, key)
    os.makedirs(out_dir, exist_ok=True)
    vertices, faces = ob.load_obj(clean_mesh_path)
    cams = ob.load_cameras(poses)
    textured_mesh = registration.load_textured_obj(
        Path(raw_obj_path), Path(raw_mtl_path),
    )
    pb = planes_doc.get("piano_base") or {}
    up_world = ob._unit(np.asarray(pb.get("up", [0.0, 1.0, 0.0]), float))
    texel_m = texel_mm / 1000.0
    planes = planes_doc.get("planes", [])
    frames: list[tuple[int, str, str, ob.PlaneFrame]] = []
    results: list[dict] = []
    reports: list[dict] = []
    total_area = 0.0
    lines = [f"Superfici piani - bake OC reference {texel_mm:.0f} mm/texel", ""]

    for index, plane in enumerate(planes, 1):
        name = plane.get("nome") or plane.get("tipo") or f"piano{index}"
        pf = ob.plane_frame(
            plane, up_world, vertices, faces, texel_m,
            scale_m_per_mesh_unit=scale_m_per_mesh_unit,
        )
        if pf is None:
            log(f"  piano {index} ({name}): degenere, salto")
            continue
        rgba, coverage, used, report = _compose_plane(
            textured_mesh, pf, plane, cams, photo_resolver,
            scale_m_per_mesh_unit=scale_m_per_mesh_unit,
            max_photos=max_photos,
            coverage_photos=coverage_photos,
            crop=crop,
            depth_m=2.0,
            max_residual_px=40.0,
            max_rotation_deg=0.5,
            max_scale_error=0.03,
        )
        filename = f"plane_{index}_{ob._sanitize(name)}.png"
        cv2.imwrite(os.path.join(out_dir, filename), cv2.cvtColor(rgba, cv2.COLOR_RGBA2BGRA))
        area = pf.area_m2
        total_area += area
        result = {
            "index": index, "nome": name, "file": filename,
            "width_m": round(pf.width_m, 3), "height_m": round(pf.height_m, 3),
            "tex_w": pf.tex_w, "tex_h": pf.tex_h,
            "area_m2": round(area, 2), "coverage": round(coverage, 3),
            "photos_used": len(used), "registered_photos": report["registered_photos"],
            "projection_mode": "oc_reference_registered",
        }
        results.append(result)
        reports.append({"index": index, "nome": name, **report})
        frames.append((index, name, filename, pf))
        lines.append(
            f"plane_{index}_{name:<16.16s} {pf.width_m:6.2f} x {pf.height_m:6.2f} m "
            f"{area:8.2f} m2   copertura {coverage * 100:3.0f}%",
        )
        log(
            f"  piano {index} ({name}): {pf.tex_w}x{pf.tex_h}px, "
            f"{len(used)} foto, copertura {coverage * 100:.0f}%",
        )
        if progress:
            progress(index, len(planes), name)
        gc.collect()

    lines += ["", f"TOTALE {total_area:8.2f} m2"]
    Path(out_dir, "_superfici.txt").write_text("\n".join(lines) + "\n")
    Path(out_dir, "_registration.json").write_text(
        json.dumps({"schema": "acro.oc-reference-registration/v1", "planes": reports},
                   indent=2, ensure_ascii=False),
    )
    main_obj, _ = ob._write_textured_mesh(out_dir, frames)
    coverage = (
        sum(item["coverage"] * item["area_m2"] for item in results) / total_area
        if total_area > 0 else 0.0
    )
    return {
        "planes": results,
        "total_area_m2": round(total_area, 2),
        "coverage": round(coverage, 3),
        "main_obj": main_obj,
        "out_dir": out_dir,
        "count": len(results),
        "projection_mode": "oc_reference_registered",
    }
