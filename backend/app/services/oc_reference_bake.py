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
import math
import os
from pathlib import Path

import cv2
import numpy as np

from . import ortho_bake as ob
from scripts import run_oc_reference_registration_local as registration
from scripts.oc_compositing import coverage_rgba, mosaic


def _write_texture_png(path: str, bgra: np.ndarray) -> None:
    """Scrive il buffer OpenCV BGRA senza reinterpretarne i canali."""
    if not cv2.imwrite(path, bgra):
        raise RuntimeError(f"Impossibile scrivere la texture: {path}")


def _identity_correction() -> dict[str, object]:
    return {
        "offset_x": 0.0,
        "offset_y": 0.0,
        "rotation_deg": 0.0,
        "scale": 1.0,
        "matrix": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    }


def adaptive_registration_budget(
    pf: ob.PlaneFrame,
    base_photos: int = 12,
    max_photos: int = 32,
) -> int:
    """Dimensiona il tetto di registrazione dalla superficie reale del piano."""
    span_need = math.ceil(pf.width_m / 3.0)
    area_need = math.ceil(pf.area_m2 / 40.0)
    return min(max(max_photos, base_photos), max(base_photos, span_need, area_need))


def _select_registration_candidates(
    pf: ob.PlaneFrame,
    normal: np.ndarray,
    cams: list[ob.Camera],
    ranked: list[dict],
    *,
    crop: float,
    base_photos: int,
    max_photos: int,
) -> tuple[list[dict], dict]:
    """Seleziona viste distribuite finche il piano ha due coperture frontali."""
    budget = adaptive_registration_budget(pf, base_photos, max_photos)
    if not ranked or budget <= 0:
        return [], {"budget": budget, "selected": 0}

    grid_w = min(180, max(24, int(math.ceil(pf.width_m / 0.25))))
    grid_h = min(180, max(24, int(math.ceil(pf.height_m / 0.25))))
    cols, rows = np.meshgrid(np.arange(grid_w), np.arange(grid_h))
    gu = (cols.reshape(-1) + 0.5) / grid_w * pf.width_world
    gv = (1.0 - (rows.reshape(-1) + 0.5) / grid_h) * pf.height_world
    world = pf.origin + gu[:, None] * pf.u + gv[:, None] * pf.v
    polygon = ob._polygon_mask(grid_w, grid_h, pf.polygon_uv).reshape(-1)
    polygon_cells = max(int(polygon.sum()), 1)
    quality_margin = max((1.0 - crop) * 0.5, 0.12)
    camera_by_key = {str(int(cam.key)): cam for cam in cams}
    masks: list[np.ndarray] = []
    usable_ranked: list[dict] = []
    n = ob._unit(np.asarray(normal, float))

    for candidate in ranked[:120]:
        cam = camera_by_key.get(str(candidate["key"]))
        if cam is None:
            continue
        x, y, z = ob._project(cam, world)
        to_camera = cam.C - world
        distance = np.linalg.norm(to_camera, axis=1)
        facing = (to_camera / np.maximum(distance[:, None], 1e-6)) @ n
        mask = (
            polygon
            & (z > 0.01)
            & (facing >= 0.342)
            & (x >= quality_margin * cam.image_width)
            & (x <= (1.0 - quality_margin) * cam.image_width)
            & (y >= quality_margin * cam.image_height)
            & (y <= (1.0 - quality_margin) * cam.image_height)
        )
        if mask.any():
            usable_ranked.append(candidate)
            masks.append(mask)

    selected: list[dict] = []
    selected_ids: set[int] = set()
    coverage_count = np.zeros(len(world), np.uint8)
    minimum = min(base_photos, len(usable_ranked))

    while len(selected) < min(budget, len(usable_ranked)):
        deficit = polygon & (coverage_count < 2)
        best_index = -1
        best_gain = -1
        best_overlap = -1
        covered = coverage_count > 0
        for index, mask in enumerate(masks):
            if index in selected_ids:
                continue
            gain = int((mask & deficit).sum())
            overlap = int((mask & covered).sum()) if selected else 0
            if gain > best_gain or (gain == best_gain and overlap > best_overlap):
                best_index, best_gain, best_overlap = index, gain, overlap
        if best_index < 0:
            break
        single_coverage = float((coverage_count[polygon] >= 1).mean())
        double_coverage = float((coverage_count[polygon] >= 2).mean())
        if (len(selected) >= minimum and single_coverage >= 0.995
                and double_coverage >= 0.95):
            break
        if len(selected) >= minimum and best_gain < max(1, int(polygon_cells * 0.002)):
            break
        selected_ids.add(best_index)
        selected.append(usable_ranked[best_index])
        coverage_count[masks[best_index]] += 1

    # Mantiene il baseline anche quando le maschere centrali sono troppo severe.
    selected_keys = {str(item["key"]) for item in selected}
    for candidate in ranked:
        if len(selected) >= min(base_photos, len(ranked)) or len(selected) >= budget:
            break
        if str(candidate["key"]) not in selected_keys:
            selected.append(candidate)
            selected_keys.add(str(candidate["key"]))

    single_coverage = float((coverage_count[polygon] >= 1).mean())
    double_coverage = float((coverage_count[polygon] >= 2).mean())
    return selected, {
        "budget": budget,
        "selected": len(selected),
        "single_coverage": round(single_coverage, 4),
        "double_coverage": round(double_coverage, 4),
        "grid": [grid_w, grid_h],
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
    registration_ceiling: int,
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

    can_register = int(planar_reference.sum()) >= 8_000
    if can_register:
        sift = cv2.SIFT_create(nfeatures=5000, contrastThreshold=0.025, edgeThreshold=12)
        reference_points, reference_descriptors = sift.detectAndCompute(
            registration._normalized_gray(reference),
            planar_reference.astype(np.uint8) * 255,
        )
    else:
        reference_points, reference_descriptors = [], None
    ranked = registration.rank_candidates(pf, normal, cams, crop=crop)
    camera_by_key = {str(int(cam.key)): cam for cam in cams}

    accepted_images: list[np.ndarray] = []
    accepted_planar_masks: list[np.ndarray] = []
    accepted_full_masks: list[np.ndarray] = []
    accepted_keys: list[str] = []
    photo_reports: list[dict[str, object]] = []

    if can_register:
        registration_candidates, selection_report = _select_registration_candidates(
            pf, normal, cams, ranked, crop=crop,
            base_photos=max_photos, max_photos=registration_ceiling,
        )
    else:
        registration_candidates, selection_report = [], {
            "budget": 0, "selected": 0, "reason": "riferimento planare insufficiente",
        }
    for rank, candidate in enumerate(registration_candidates, 1):
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
    filler_start = 0
    filler_limit = max(max_photos, coverage_photos)
    for rank, candidate in enumerate(ranked[filler_start:filler_limit], filler_start + 1):
        key = str(candidate["key"])
        if key in accepted_keys:
            continue
        cam = camera_by_key[key]
        predicted_mask = registration.photo_coverage_mask(cam, pf)
        new_pixels = predicted_mask & ~covered
        if int(new_pixels.sum()) < 200:
            continue
        resolved = photo_resolver(key)
        if not resolved:
            continue
        posed, posed_mask = registration.warp_photo_to_plane(Path(resolved), cam, pf)
        accepted_images.append(posed)
        compositing_masks.append(posed_mask)
        accepted_keys.append(key)
        filler_report = {
            "rank": rank, **candidate, "photo_found": True,
            "registration": {
                "accepted": True,
                "reason": "riempimento copertura da posa",
                "pose_only_filler": True,
                "global_correction": _identity_correction(),
            },
        }
        existing = next(
            (report for report in photo_reports if str(report.get("key")) == key),
            None,
        )
        if existing is None:
            photo_reports.append(filler_report)
        else:
            existing.update(filler_report)
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
        "registration_selection": selection_report,
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
    registration_ceiling: int = 32,
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
            registration_ceiling=registration_ceiling,
            coverage_photos=coverage_photos,
            crop=crop,
            depth_m=2.0,
            max_residual_px=40.0,
            max_rotation_deg=0.5,
            max_scale_error=0.03,
        )
        filename = f"plane_{index}_{ob._sanitize(name)}.png"
        # Tutta la pipeline OpenCV mantiene BGR/BGRA. Un ulteriore RGBA→BGRA
        # scambiava rosso e blu e produceva la dominante azzurra nei PNG.
        _write_texture_png(os.path.join(out_dir, filename), rgba)
        area = pf.area_m2
        total_area += area
        result = {
            "index": index, "nome": name, "file": filename,
            "width_m": round(pf.width_m, 3), "height_m": round(pf.height_m, 3),
            "tex_w": pf.tex_w, "tex_h": pf.tex_h,
            "area_m2": round(area, 2), "coverage": round(coverage, 3),
            "photos_used": len(used), "registered_photos": report["registered_photos"],
            "registration_budget": report["registration_selection"].get("budget", 0),
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
        "texture_encoding": "sRGB",
    }
