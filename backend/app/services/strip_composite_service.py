"""Composite a fasce bottom→top della facciata.

Filosofia (vedi spec product 2026-05-25):
- Ogni foto viene **keystone-verticale** corretta (verticali parallele).
- NIENTE correzione orizzontali per-foto (= no wall_normal, no ortografica
  individuale).
- NIENTE cv2.Stitcher, niente homography locali, niente ORB-triangulation 3D.
- Estraiamo una **fascia centrale** da ogni foto (crop, scarta bordi deformati).
- Compositiamo le fasce in ordine `order_index` (bottom→top) usando SOLO
  traslazioni `(dx, dy)` calcolate via **phase correlation** sull'overlap.
- Feather blending nell'overlap, niente media globale.

Output: un "composite operativo" `facade_strip_composite.jpg`. **NON** è
un'ortofoto: la prospettiva laterale e la scala metrica si correggono DOPO
con homography 4-tap + 2-tap di scala sul composite finale.
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional
from functools import lru_cache
import math

import cv2
import numpy as np

from .keystone_correction import (
    _roll_deg_from_transform,
    _rotate_image_around_center,
    keystone_correct,
)


# ─────────────────────── Dati struttura ───────────────────────

@dataclass
class StripPlacement:
    """Posizione finale di una fascia nel canvas composite."""
    order_index: int
    x_offset: int           # canvas X (left edge of strip)
    y_offset: int           # canvas Y (top edge of strip)
    width: int
    height: int
    match_response: float   # 0…1, quality of phase correlation
    match_method: str       # "phase_correlation" | "orb_fallback" | "geometric_fallback" | "initial"
    dx: float               # offset orizzontale dalla strip precedente (px)
    dy: float               # offset verticale dalla strip precedente (px)
    scale: float = 1.0      # scala stimata rispetto alla strip precedente


@dataclass
class CompositeResult:
    composite: np.ndarray
    placements: list[StripPlacement]
    canvas_size: tuple[int, int]   # (W, H)
    warnings: list[str] = field(default_factory=list)
    strips: list[tuple[int, np.ndarray]] = field(default_factory=list)  # (order_index, strip BGR) per debug


@dataclass(frozen=True)
class ColumnGroup:
    """Sequenza verticale di foto appartenenti allo stesso sweep/colonna."""
    column_index: int
    order_indices: list[int]
    reason: str


@dataclass
class ColumnCompositeResult:
    column_index: int
    order_indices: list[int]
    composite: np.ndarray
    placements: list[StripPlacement]
    canvas_size: tuple[int, int]
    warnings: list[str] = field(default_factory=list)


@dataclass
class GroupedCompositeResult:
    columns: list[ColumnCompositeResult]
    groups: list[ColumnGroup]
    warnings: list[str] = field(default_factory=list)


# ─────────────────────── API principale ───────────────────────

def compose_vertical_strips(
    images: list[np.ndarray],
    metadata: list[dict],
    *,
    overlap_ratio: float = 0.45,
    crop_width_ratio: float = 0.80,
    crop_height_ratio: float = 1.00,
    feather_px: int = 60,
    weak_match_threshold: float = 0.10,
    decompose_roll: bool = False,
    post_pitch_roll: bool = False,
    post_horizontal_roll: bool = False,
    scale_alignment: bool = False,
    blend_mode: str = "feather",
) -> CompositeResult:
    """Compone le foto in un singolo composite bottom→top.

    `images` e `metadata` devono essere allineati (stesso index = stessa foto)
    e già ordinati per `order_index` ASCENDENTE (la prima è quella più in basso
    del palazzo). Ritorna composite + placements per debug.

    Parametri:
      overlap_ratio:      frazione di altezza fascia usata per il matching (0.30 = 30%)
      crop_width_ratio:   frazione di larghezza foto da tenere come fascia (0.80 = 80% centrale)
      crop_height_ratio:  frazione di altezza foto da tenere
      feather_px:         transizione alpha (px) ai bordi della fascia per il blending
      weak_match_threshold: sotto questa response di phase corr, fallback geometrico
    """
    if len(images) != len(metadata):
        raise ValueError("images e metadata devono avere stessa lunghezza")
    if len(images) == 0:
        raise ValueError("nessuna foto in input")

    warnings: list[str] = []

    # 1. Keystone verticale + crop centrale per ogni foto.
    strips: list[tuple[int, np.ndarray]] = []   # (order_index, strip BGR)
    for i, (img, m) in enumerate(zip(images, metadata)):
        order = int(m.get("order_index", i))
        ct = m.get("camera_transform")
        ki = m.get("camera_intrinsics")
        if ct is None or ki is None:
            warnings.append(f"foto {order}: metadata incompleti, skip")
            continue
        try:
            rectified, _ = keystone_correct(
                img,
                intrinsics=ki,
                camera_transform=ct,
                metadata_image_size=(int(m["image_width"]), int(m["image_height"])),
                decompose_roll=decompose_roll,
            )
            if post_pitch_roll:
                roll_deg = _roll_deg_from_transform(ct)
                rectified, _ = _rotate_image_around_center(rectified, roll_deg)
            if post_horizontal_roll:
                applied_roll = 0.0
                roll_sources: list[str] = []
                for _ in range(2):
                    roll_estimate = _estimate_horizontal_roll_deg_preferred_bands(rectified)
                    horizontal_roll = roll_estimate[0] if roll_estimate is not None else None
                    if horizontal_roll is None or abs(horizontal_roll) <= 0.35:
                        break
                    rectified, _ = _rotate_image_around_center(rectified, horizontal_roll)
                    roll_sources.append(roll_estimate[1])
                    applied_roll += float(horizontal_roll)
                if abs(applied_roll) > 0.25:
                    source = "/".join(roll_sources) if roll_sources else "global"
                    warnings.append(f"foto {order}: horizontal_roll {applied_roll:+.2f}deg ({source})")
        except Exception as e:
            warnings.append(f"foto {order}: keystone fallito: {e}")
            continue
        h, w = rectified.shape[:2]
        cw = max(1, int(round(w * crop_width_ratio)))
        ch = max(1, int(round(h * crop_height_ratio)))
        x0 = (w - cw) // 2
        y0 = (h - ch) // 2
        strip = rectified[y0:y0 + ch, x0:x0 + cw].copy()
        strips.append((order, strip))

    if not strips:
        raise ValueError("Nessuna fascia valida prodotta")

    # 2. Ordina strip per order_index (per sicurezza)
    strips.sort(key=lambda x: x[0])

    if scale_alignment and len(strips) >= 2:
        return _compose_scaled_strips(
            strips,
            metadata,
            overlap_ratio=overlap_ratio,
            feather_px=feather_px,
            weak_match_threshold=weak_match_threshold,
            warnings=warnings,
            blend_mode=blend_mode,
        )

    # 3. Per ogni coppia adiacente trova offset (dx, dy)
    placements: list[StripPlacement] = []
    first_order, first_strip = strips[0]
    placements.append(StripPlacement(
        order_index=first_order,
        x_offset=0, y_offset=0,
        width=first_strip.shape[1], height=first_strip.shape[0],
        match_response=1.0, match_method="initial",
        dx=0.0, dy=0.0,
        scale=1.0,
    ))

    for i in range(1, len(strips)):
        prev_order, prev_strip = strips[i - 1]
        curr_order, curr_strip = strips[i]
        # Metadata per la geometric fallback (pitch difference) — recupero dai metadata originali
        prev_meta = next((m for m in metadata if int(m.get("order_index", -1)) == prev_order), None)
        curr_meta = next((m for m in metadata if int(m.get("order_index", -1)) == curr_order), None)
        dx, dy, response, method, w = _match_strips(
            prev_strip, curr_strip,
            overlap_ratio=overlap_ratio,
            weak_threshold=weak_match_threshold,
            prev_meta=prev_meta, curr_meta=curr_meta,
        )
        if w: warnings.append(f"pair {prev_order}↔{curr_order}: {w}")

        prev_pl = placements[-1]
        # IDEAL: O_y_ideal = prev.y_offset - (h_curr - h_overlap) — strip i sopra strip i-1
        # con la BOTTOM-overlap di curr che combacia con TOP-overlap di prev.
        h_curr = curr_strip.shape[0]
        h_prev = prev_strip.shape[0]
        h_overlap = int(min(h_prev, h_curr) * overlap_ratio)
        # Sign convention: phaseCorrelate(prev_top, curr_bottom) returns shift such
        # that curr_bottom = prev_top shifted by (dx, dy). Per allineare,
        # spostiamo curr in canvas di -(dx, dy).
        O_y_ideal = prev_pl.y_offset - (h_curr - h_overlap)
        O_x = prev_pl.x_offset - int(round(dx))
        O_y = O_y_ideal - int(round(dy))

        placements.append(StripPlacement(
            order_index=curr_order,
            x_offset=O_x, y_offset=O_y,
            width=curr_strip.shape[1], height=curr_strip.shape[0],
            match_response=float(response), match_method=method,
            dx=float(dx), dy=float(dy),
            scale=1.0,
        ))

    # 4. Trasla tutti i placement per avere x_min=0, y_min=0 nel canvas
    x_min = min(p.x_offset for p in placements)
    y_min = min(p.y_offset for p in placements)
    x_max = max(p.x_offset + p.width  for p in placements)
    y_max = max(p.y_offset + p.height for p in placements)
    canvas_w = x_max - x_min
    canvas_h = y_max - y_min
    adjusted = [
        StripPlacement(
            order_index=p.order_index,
            x_offset=p.x_offset - x_min,
            y_offset=p.y_offset - y_min,
            width=p.width, height=p.height,
            match_response=p.match_response, match_method=p.match_method,
            dx=p.dx, dy=p.dy,
            scale=p.scale,
        )
        for p in placements
    ]

    # 5. Build canvas + feather blending
    canvas = np.zeros((canvas_h, canvas_w, 3), dtype=np.float32)
    weight = np.zeros((canvas_h, canvas_w), dtype=np.float32)
    for (_, strip), p in zip(strips, adjusted):
        mask = _feather_mask(strip.shape[:2], feather_px=feather_px)
        x0, y0 = p.x_offset, p.y_offset
        x1 = min(x0 + strip.shape[1], canvas_w)
        y1 = min(y0 + strip.shape[0], canvas_h)
        sx = x1 - x0; sy = y1 - y0
        if sx <= 0 or sy <= 0: continue
        roi_strip = strip[:sy, :sx].astype(np.float32)
        roi_mask  = mask[:sy, :sx]
        canvas[y0:y1, x0:x1] += roi_strip * roi_mask[..., None]
        weight[y0:y1, x0:x1] += roi_mask
    # Normalizza dove ci sono contributi
    safe_weight = np.maximum(weight, 1e-6)
    composite = (canvas / safe_weight[..., None]).clip(0, 255).astype(np.uint8)

    return CompositeResult(
        composite=composite,
        placements=adjusted,
        canvas_size=(canvas_w, canvas_h),
        warnings=warnings,
        strips=strips,
    )


def group_metadata_into_columns(
    metadata: list[dict],
    *,
    pitch_reset_deg: float = 20.0,
    lateral_reset_m: float = 1.25,
) -> list[ColumnGroup]:
    """Raggruppa una sessione in colonne verticali.

    Regola principale: dentro una colonna il pitch cresce mentre l'operatore
    fotografa dal basso verso l'alto. Quando il pitch scende molto rispetto
    allo scatto precedente, è quasi sempre iniziata una nuova colonna. Usiamo
    anche lo spostamento orizzontale ARKit come conferma quando disponibile.
    """
    if not metadata:
        return []

    ordered = sorted(metadata, key=lambda m: int(m.get("order_index", 0)))
    groups: list[ColumnGroup] = []
    current: list[int] = []
    start_reason = "initial"

    prev_m: dict | None = None
    for m in ordered:
        order = int(m.get("order_index", len(current)))
        if prev_m is not None:
            prev_pitch = _pitch_deg(prev_m)
            curr_pitch = _pitch_deg(m)
            lateral = _horizontal_camera_distance(prev_m, m)
            pitch_drop = prev_pitch - curr_pitch
            starts_new = pitch_drop >= pitch_reset_deg
            if lateral is not None and lateral >= lateral_reset_m and curr_pitch <= prev_pitch:
                starts_new = True
            if starts_new and current:
                reason = f"pitch_reset {pitch_drop:.1f}deg"
                if lateral is not None:
                    reason += f", lateral {lateral:.2f}m"
                groups.append(ColumnGroup(
                    column_index=len(groups),
                    order_indices=current,
                    reason=start_reason,
                ))
                current = []
                start_reason = reason
        current.append(order)
        prev_m = m

    if current:
        groups.append(ColumnGroup(
            column_index=len(groups),
            order_indices=current,
            reason=start_reason,
        ))
    return groups


def compose_column_groups(
    images: list[np.ndarray],
    metadata: list[dict],
    *,
    pitch_reset_deg: float = 20.0,
    lateral_reset_m: float = 1.25,
    overlap_ratio: float = 0.45,
    crop_width_ratio: float = 0.80,
    crop_height_ratio: float = 1.00,
    feather_px: int = 60,
    weak_match_threshold: float = 0.10,
    min_photos_per_column: int = 2,
    decompose_roll: bool = False,
    post_pitch_roll: bool = False,
    post_horizontal_roll: bool = False,
    scale_alignment: bool = False,
    blend_mode: str = "feather",
) -> GroupedCompositeResult:
    """Crea un composite verticale per ogni colonna rilevata automaticamente."""
    if len(images) != len(metadata):
        raise ValueError("images e metadata devono avere stessa lunghezza")

    pairs = sorted(zip(images, metadata), key=lambda im: int(im[1].get("order_index", 0)))
    groups = group_metadata_into_columns(
        [m for _, m in pairs],
        pitch_reset_deg=pitch_reset_deg,
        lateral_reset_m=lateral_reset_m,
    )
    by_order = {int(m.get("order_index", i)): (img, m) for i, (img, m) in enumerate(pairs)}

    columns: list[ColumnCompositeResult] = []
    warnings: list[str] = []
    for group in groups:
        if len(group.order_indices) < min_photos_per_column:
            warnings.append(
                f"colonna {group.column_index}: solo {len(group.order_indices)} foto, skip"
            )
            continue
        group_images: list[np.ndarray] = []
        group_meta: list[dict] = []
        for order in group.order_indices:
            pair = by_order.get(order)
            if pair is None:
                warnings.append(f"colonna {group.column_index}: foto {order} non trovata")
                continue
            group_images.append(pair[0])
            group_meta.append(pair[1])
        if not group_images:
            continue
        comp = compose_vertical_strips(
            group_images,
            group_meta,
            overlap_ratio=overlap_ratio,
            crop_width_ratio=crop_width_ratio,
            crop_height_ratio=crop_height_ratio,
            feather_px=feather_px,
            weak_match_threshold=weak_match_threshold,
            decompose_roll=decompose_roll,
            post_pitch_roll=post_pitch_roll,
            post_horizontal_roll=post_horizontal_roll,
            scale_alignment=scale_alignment,
            blend_mode=blend_mode,
        )
        columns.append(ColumnCompositeResult(
            column_index=group.column_index,
            order_indices=group.order_indices,
            composite=comp.composite,
            placements=comp.placements,
            canvas_size=comp.canvas_size,
            warnings=comp.warnings,
        ))

    return GroupedCompositeResult(columns=columns, groups=groups, warnings=warnings)


# ─────────────────────── Helpers privati ───────────────────────

def _pitch_deg(meta: dict) -> float:
    euler = meta.get("euler_angles") or []
    if len(euler) >= 1:
        try:
            return float(euler[0])
        except Exception:
            pass
    return 0.0


def _horizontal_camera_distance(a: dict, b: dict) -> float | None:
    ta = a.get("camera_transform")
    tb = b.get("camera_transform")
    if not ta or not tb or len(ta) != 16 or len(tb) != 16:
        return None
    ax, az = float(ta[12]), float(ta[14])
    bx, bz = float(tb[12]), float(tb[14])
    return float(np.hypot(bx - ax, bz - az))


def _compose_scaled_strips(
    strips: list[tuple[int, np.ndarray]],
    metadata: list[dict],
    *,
    overlap_ratio: float,
    feather_px: int,
    weak_match_threshold: float,
    warnings: list[str],
    blend_mode: str,
) -> CompositeResult:
    """Composita le fasce stimando per ogni coppia una similarity transform.

    La trasformazione ammessa è affine parziale: scala uniforme + rotazione
    minima + traslazione. Non usiamo omografie locali, perché piegherebbero la
    facciata in modo difficile da controllare.
    """
    transforms: list[np.ndarray] = [np.eye(3, dtype=np.float64)]
    placements: list[StripPlacement] = []
    first_order, first_strip = strips[0]
    placements.append(StripPlacement(
        order_index=first_order,
        x_offset=0,
        y_offset=0,
        width=first_strip.shape[1],
        height=first_strip.shape[0],
        match_response=1.0,
        match_method="initial",
        dx=0.0,
        dy=0.0,
        scale=1.0,
    ))

    for i in range(1, len(strips)):
        prev_order, prev_strip = strips[i - 1]
        curr_order, curr_strip = strips[i]
        prev_meta = next((m for m in metadata if int(m.get("order_index", -1)) == prev_order), None)
        curr_meta = next((m for m in metadata if int(m.get("order_index", -1)) == curr_order), None)
        M_rel, response, method, warning, scale = _match_strips_similarity(
            prev_strip,
            curr_strip,
            overlap_ratio=overlap_ratio,
            weak_threshold=weak_match_threshold,
            prev_meta=prev_meta,
            curr_meta=curr_meta,
        )
        if warning:
            warnings.append(f"pair {prev_order}↔{curr_order}: {warning}")

        transforms.append(transforms[-1] @ M_rel)
        dx = float(M_rel[0, 2])
        dy = float(M_rel[1, 2])
        h, w = curr_strip.shape[:2]
        corners = np.array([[0, 0, 1], [w, 0, 1], [w, h, 1], [0, h, 1]], dtype=np.float64).T
        warped = transforms[-1] @ corners
        xs = warped[0] / warped[2]
        ys = warped[1] / warped[2]
        placements.append(StripPlacement(
            order_index=curr_order,
            x_offset=int(np.floor(xs.min())),
            y_offset=int(np.floor(ys.min())),
            width=int(np.ceil(xs.max() - xs.min())),
            height=int(np.ceil(ys.max() - ys.min())),
            match_response=float(response),
            match_method=method,
            dx=dx,
            dy=dy,
            scale=float(scale),
        ))

    # Calcola canvas bounds in coordinate globali.
    all_x: list[float] = []
    all_y: list[float] = []
    for idx, ((_, strip), M) in enumerate(zip(strips, transforms)):
        h, w = strip.shape[:2]
        visible_h = _visible_strip_height(h, overlap_ratio, trim_bottom=idx > 0)
        corners = np.array(
            [[0, 0, 1], [w, 0, 1], [w, visible_h, 1], [0, visible_h, 1]],
            dtype=np.float64,
        ).T
        warped = M @ corners
        all_x.extend((warped[0] / warped[2]).tolist())
        all_y.extend((warped[1] / warped[2]).tolist())
    x_min, x_max = float(min(all_x)), float(max(all_x))
    y_min, y_max = float(min(all_y)), float(max(all_y))
    canvas_w = max(1, int(np.ceil(x_max - x_min)))
    canvas_h = max(1, int(np.ceil(y_max - y_min)))
    T = np.array([[1.0, 0.0, -x_min], [0.0, 1.0, -y_min], [0.0, 0.0, 1.0]], dtype=np.float64)

    adjusted: list[StripPlacement] = []
    if blend_mode == "graphcut":
        warped_images: list[np.ndarray] = []
        warped_masks: list[np.ndarray] = []
        corners_for_seam: list[tuple[int, int]] = []
    elif blend_mode == "cut":
        canvas_u8 = np.zeros((canvas_h, canvas_w, 3), dtype=np.uint8)
    else:
        canvas = np.zeros((canvas_h, canvas_w, 3), dtype=np.float32)
        weight = np.zeros((canvas_h, canvas_w), dtype=np.float32)

    for idx, ((order, strip), p, M) in enumerate(zip(strips, placements, transforms)):
        M_canvas = T @ M
        A = M_canvas[:2, :]
        h, w = strip.shape[:2]
        content_mask = _content_mask(strip)
        if idx > 0:
            # La fascia bassa della foto superiore serve per stimare il match
            # con la foto sotto. Incollarla di nuovo duplica contenuti già visti.
            visible_h = _visible_strip_height(h, overlap_ratio, trim_bottom=True)
            content_mask[visible_h:, :] = 0.0
        if blend_mode in ("cut", "graphcut"):
            mask = content_mask
        else:
            mask = _feather_mask((h, w), feather_px=feather_px) * content_mask
        warped_img = cv2.warpAffine(
            strip.astype(np.float32) if blend_mode != "cut" else strip,
            A,
            (canvas_w, canvas_h),
            flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=(0, 0, 0),
        )
        warped_mask = cv2.warpAffine(
            mask,
            A,
            (canvas_w, canvas_h),
            flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=0,
        )
        if blend_mode == "graphcut":
            warped_images.append(warped_img.astype(np.uint8))
            warped_masks.append((warped_mask > 0.5).astype(np.uint8) * 255)
            corners_for_seam.append((0, 0))
        elif blend_mode == "cut":
            take = warped_mask > 0.5
            canvas_u8[take] = warped_img[take]
        else:
            canvas += warped_img * warped_mask[..., None]
            weight += warped_mask

        visible_h = _visible_strip_height(h, overlap_ratio, trim_bottom=idx > 0)
        corners = np.array(
            [[0, 0, 1], [w, 0, 1], [w, visible_h, 1], [0, visible_h, 1]],
            dtype=np.float64,
        ).T
        warped = M_canvas @ corners
        xs = warped[0] / warped[2]
        ys = warped[1] / warped[2]
        adjusted.append(StripPlacement(
            order_index=order,
            x_offset=int(np.floor(xs.min())),
            y_offset=int(np.floor(ys.min())),
            width=int(np.ceil(xs.max() - xs.min())),
            height=int(np.ceil(ys.max() - ys.min())),
            match_response=p.match_response,
            match_method=p.match_method,
            dx=p.dx,
            dy=p.dy,
            scale=p.scale,
        ))

    if blend_mode == "graphcut":
        composite = _graphcut_multiband_blend(warped_images, warped_masks, corners_for_seam, canvas_w, canvas_h)
    elif blend_mode == "cut":
        composite = canvas_u8
    else:
        safe_weight = np.maximum(weight, 1e-6)
        composite = (canvas / safe_weight[..., None]).clip(0, 255).astype(np.uint8)
    return CompositeResult(
        composite=composite,
        placements=adjusted,
        canvas_size=(canvas_w, canvas_h),
        warnings=warnings,
        strips=strips,
    )


def _match_strips_similarity(
    prev_strip: np.ndarray,
    curr_strip: np.ndarray,
    *,
    overlap_ratio: float,
    weak_threshold: float,
    prev_meta: Optional[dict] = None,
    curr_meta: Optional[dict] = None,
) -> tuple[np.ndarray, float, str, Optional[str], float]:
    """Stima curr_strip -> prev_strip con scala uniforme + rotazione + traslazione."""
    h_prev, w_prev = prev_strip.shape[:2]
    h_curr, w_curr = curr_strip.shape[:2]
    h_overlap_prev = max(20, int(h_prev * overlap_ratio))
    h_overlap_curr = max(20, int(h_curr * overlap_ratio))
    prev_top = prev_strip[:h_overlap_prev, :]
    curr_bottom = curr_strip[-h_overlap_curr:, :]

    try:
        loftr_result = _estimate_similarity_from_loftr(
            prev_top,
            curr_bottom,
            h_curr=h_curr,
            h_overlap_curr=h_overlap_curr,
        )
        if loftr_result is not None:
            M, response, scale = loftr_result
            return M, response, "loftr_overlap_similarity", None, scale
    except Exception:
        pass

    try:
        sift_result = _estimate_similarity_from_features(
            prev_top,
            curr_bottom,
            detector_name="sift",
            h_curr=h_curr,
            h_overlap_curr=h_overlap_curr,
        )
        if sift_result is not None:
            M, response, scale = sift_result
            return M, response, "sift_overlap_similarity", None, scale
    except Exception:
        pass

    try:
        akaze_result = _estimate_similarity_from_features(
            prev_top,
            curr_bottom,
            detector_name="akaze",
            h_curr=h_curr,
            h_overlap_curr=h_overlap_curr,
        )
        if akaze_result is not None:
            M, response, scale = akaze_result
            return M, response, "akaze_overlap_similarity", None, scale
    except Exception:
        pass

    try:
        orb = cv2.ORB_create(nfeatures=1500)
        g_prev = cv2.cvtColor(prev_top, cv2.COLOR_BGR2GRAY)
        g_curr = cv2.cvtColor(curr_bottom, cv2.COLOR_BGR2GRAY)
        kp_prev, ds_prev = orb.detectAndCompute(g_prev, None)
        kp_curr, ds_curr = orb.detectAndCompute(g_curr, None)
        if ds_prev is not None and ds_curr is not None and len(kp_prev) >= 10 and len(kp_curr) >= 10:
            bf = cv2.BFMatcher(cv2.NORM_HAMMING)
            knn = bf.knnMatch(ds_curr, ds_prev, k=2)
            good = []
            for pair in knn:
                if len(pair) != 2:
                    continue
                a, b = pair
                if a.distance < 0.78 * b.distance:
                    good.append(a)
            if len(good) >= 8:
                src = np.float32([kp_curr[m.queryIdx].pt for m in good])
                dst = np.float32([kp_prev[m.trainIdx].pt for m in good])
                A, inliers = cv2.estimateAffinePartial2D(
                    src,
                    dst,
                    method=cv2.RANSAC,
                    ransacReprojThreshold=8.0,
                    maxIters=3000,
                    confidence=0.98,
                )
                if A is not None and inliers is not None:
                    inlier_count = int(inliers.sum())
                    inlier_ratio = inlier_count / max(1, len(good))
                    scale = float(np.sqrt(A[0, 0] ** 2 + A[1, 0] ** 2))
                    if 0.65 <= scale <= 2.30 and inlier_count >= 6 and inlier_ratio >= 0.25:
                        # A lavora sulle coordinate della patch curr_bottom.
                        # Convertiamo da coordinate curr_strip intere a prev_strip.
                        patch_to_full = np.array([
                            [1.0, 0.0, 0.0],
                            [0.0, 1.0, -(h_curr - h_overlap_curr)],
                            [0.0, 0.0, 1.0],
                        ], dtype=np.float64)
                        A3 = np.vstack([A.astype(np.float64), [0.0, 0.0, 1.0]])
                        M = A3 @ patch_to_full
                        response = float(min(1.0, inlier_ratio))
                        return M, response, "orb_similarity", None, scale
    except Exception as e:
        sim_warning = f"similarity eccezione: {e}"
    else:
        sim_warning = "similarity debole"

    band_result = _match_strips_band_similarity(
        prev_top,
        curr_bottom,
        h_curr=h_curr,
        h_overlap_curr=h_overlap_curr,
    )
    if band_result is not None:
        M, response, scale = band_result
        return M, response, "band_constrained_similarity", sim_warning, scale

    dx, dy, response, method, warning = _match_strips(
        prev_strip,
        curr_strip,
        overlap_ratio=overlap_ratio,
        weak_threshold=weak_threshold,
        prev_meta=prev_meta,
        curr_meta=curr_meta,
    )
    h_overlap = int(min(h_prev, h_curr) * overlap_ratio)
    M = np.array([
        [1.0, 0.0, -float(dx)],
        [0.0, 1.0, -float(h_curr - h_overlap) - float(dy)],
        [0.0, 0.0, 1.0],
    ], dtype=np.float64)
    combined_warning = sim_warning
    if warning:
        combined_warning += f"; {warning}"
    return M, response, method, combined_warning, 1.0


def _visible_strip_height(height: int, overlap_ratio: float, *, trim_bottom: bool) -> int:
    """Altezza realmente incollata: la fascia bassa superiore è solo per match."""
    if not trim_bottom:
        return height
    overlap = max(20, int(height * overlap_ratio))
    return max(1, height - overlap)


def _match_strips_band_similarity(
    prev_top: np.ndarray,
    curr_bottom: np.ndarray,
    *,
    h_curr: int,
    h_overlap_curr: int,
) -> tuple[np.ndarray, float, float] | None:
    """Allinea bottom(curr) a top(prev) con una similarity locale vincolata.

    È il fallback operativo per colonne verticali: stima scala, rotazione e
    traslazione usando solo le due bande che devono saldarsi. Non usa feature
    sparse su tutta l'immagine e non introduce omografie.
    """
    prev_box = _usable_content_bbox(prev_top)
    curr_box = _usable_content_bbox(curr_bottom)
    if prev_box is None or curr_box is None:
        return None

    px1, py1, px2, py2 = prev_box
    cx1, cy1, cx2, cy2 = curr_box
    prev_w = max(1.0, float(px2 - px1 + 1))
    curr_w = max(1.0, float(cx2 - cx1 + 1))
    scale = prev_w / curr_w
    # Fra due scatti consecutivi della stessa colonna la scala può cambiare,
    # ma un salto vicino a 2x è quasi sempre causato dal trapezio nero che
    # restringe la bbox utile della foto superiore.
    if not (0.55 <= scale <= 1.45):
        return None

    prev_angle = _estimate_horizontal_roll_deg(prev_top) or 0.0
    curr_angle = _estimate_horizontal_roll_deg(curr_bottom) or 0.0
    rot_deg = max(-12.0, min(12.0, curr_angle - prev_angle))
    theta = math.radians(rot_deg)
    c = math.cos(theta) * scale
    s = math.sin(theta) * scale

    prev_center = np.array([(px1 + px2) * 0.5, (py1 + py2) * 0.5], dtype=np.float64)
    patch_y0 = h_curr - h_overlap_curr
    curr_center_full = np.array([
        (cx1 + cx2) * 0.5,
        patch_y0 + (cy1 + cy2) * 0.5,
    ], dtype=np.float64)
    A = np.array([[c, -s], [s, c]], dtype=np.float64)
    t = prev_center - A @ curr_center_full

    refined = _refine_band_translation(prev_top, curr_bottom, A, t, patch_y0)
    if refined is not None:
        t, refine_response = refined
        response = float(max(0.05, min(1.0, refine_response)))
    else:
        response = float(max(0.05, 1.0 - min(abs(rot_deg), 12.0) / 24.0))

    M = np.array([
        [A[0, 0], A[0, 1], t[0]],
        [A[1, 0], A[1, 1], t[1]],
        [0.0, 0.0, 1.0],
    ], dtype=np.float64)
    return M, response, scale


def _refine_band_translation(
    prev_top: np.ndarray,
    curr_bottom: np.ndarray,
    A: np.ndarray,
    t: np.ndarray,
    patch_y0: int,
) -> tuple[np.ndarray, float] | None:
    """Rifinisce la traslazione locale dopo scala/rotazione.

    La stima iniziale usa la larghezza utile; qui controlliamo i pixel reali:
    warpiamo `curr_bottom` nello spazio di `prev_top` e usiamo phase
    correlation sulle parti fotografiche, ignorando i triangoli neri.
    """
    h_prev, w_prev = prev_top.shape[:2]
    patch_offset = np.array([0.0, float(patch_y0)], dtype=np.float64)
    t_patch = t + A @ patch_offset
    affine = np.hstack([A, t_patch.reshape(2, 1)]).astype(np.float64)

    curr_gray = cv2.cvtColor(curr_bottom, cv2.COLOR_BGR2GRAY).astype(np.float32)
    prev_gray = cv2.cvtColor(prev_top, cv2.COLOR_BGR2GRAY).astype(np.float32)
    curr_mask = _content_mask(curr_bottom).astype(np.float32)
    prev_mask = _content_mask(prev_top).astype(np.float32)

    warped = cv2.warpAffine(
        curr_gray,
        affine,
        (w_prev, h_prev),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
    warped_mask = cv2.warpAffine(
        curr_mask,
        affine,
        (w_prev, h_prev),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
    overlap_mask = ((warped_mask > 0.5) & (prev_mask > 0.5)).astype(np.float32)
    if float(overlap_mask.mean()) < 0.08:
        return None

    prev_norm = _normalize_for_phase(prev_gray, overlap_mask)
    curr_norm = _normalize_for_phase(warped, overlap_mask)
    try:
        (dx, dy), response = cv2.phaseCorrelate(prev_norm, curr_norm, overlap_mask)
    except Exception:
        return None
    if not np.isfinite(dx) or not np.isfinite(dy) or response < 0.03:
        return None
    if abs(dx) > w_prev * 0.35 or abs(dy) > h_prev * 0.35:
        return None

    refined_t = t - np.array([float(dx), float(dy)], dtype=np.float64)
    return refined_t, float(response)


def _normalize_for_phase(gray: np.ndarray, mask: np.ndarray) -> np.ndarray:
    values = gray[mask > 0.5]
    if values.size == 0:
        return np.zeros_like(gray, dtype=np.float32)
    mean = float(values.mean())
    std = float(values.std())
    if std < 1.0:
        std = 1.0
    out = ((gray - mean) / std).astype(np.float32)
    out *= mask.astype(np.float32)
    return out


def _estimate_horizontal_roll_deg(img: np.ndarray) -> float | None:
    """Stima una piccola rotazione 2D usando solo linee quasi orizzontali.

    Dopo la correzione pitch, molte facciate hanno cornici, davanzali, balconi
    o marcapiani quasi orizzontali. Usiamo quelle linee per rifinire il roll
    visivo, senza usare verticali e senza introdurre omografie locali.
    """
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    mask = _content_mask(img)
    gray = cv2.bitwise_and(gray, gray, mask=(mask > 0.5).astype(np.uint8) * 255)

    h, w = gray.shape[:2]
    max_dim = max(h, w)
    scale = 1600.0 / max_dim if max_dim > 1600 else 1.0
    if scale < 1.0:
        gray_small = cv2.resize(gray, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    else:
        gray_small = gray

    gray_small = cv2.GaussianBlur(gray_small, (5, 5), 0)
    edges = cv2.Canny(gray_small, 60, 160)
    min_len = max(80, int(gray_small.shape[1] * 0.12))
    lines = cv2.HoughLinesP(
        edges,
        rho=1,
        theta=np.pi / 180,
        threshold=70,
        minLineLength=min_len,
        maxLineGap=18,
    )
    if lines is None:
        return None

    angles: list[float] = []
    weights: list[float] = []
    for line in lines[:, 0, :]:
        x1, y1, x2, y2 = [float(v) for v in line]
        dx = x2 - x1
        dy = y2 - y1
        length = math.hypot(dx, dy)
        if length < min_len:
            continue
        angle = math.degrees(math.atan2(dy, dx))
        while angle <= -90:
            angle += 180
        while angle > 90:
            angle -= 180
        if abs(angle) <= 18:
            angles.append(float(angle))
            weights.append(float(length))

    if len(angles) < 4:
        return None

    order = np.argsort(np.array(angles))
    a = np.array(angles, dtype=np.float64)[order]
    w = np.array(weights, dtype=np.float64)[order]
    c = np.cumsum(w)
    median = float(a[int(np.searchsorted(c, c[-1] * 0.5))])
    return max(-14.0, min(14.0, median))


def _estimate_horizontal_roll_deg_preferred_bands(img: np.ndarray) -> tuple[float, str] | None:
    """Stima roll con priorità: H/V ortogonali, H basso, V globale.

    La coppia orizzontale+verticale quasi a 90 gradi è il segnale più forte
    che stiamo leggendo il piano facciata. Se manca, per il compositing
    verticale usiamo le orizzontali basse, cioè la zona di saldatura con la
    foto sottostante. Se mancano anche quelle, proviamo le sole verticali.
    """
    orthogonal = _estimate_horizontal_roll_deg_fld_orthogonal(img)
    if orthogonal is not None:
        return orthogonal, "ortogonale"

    h = img.shape[0]
    low = img[int(h * 0.65):int(h * 0.95), :]
    if low.shape[0] >= 80:
        low_angle = _estimate_horizontal_roll_deg_fld(low)
        if low_angle is None:
            low_angle = _estimate_horizontal_roll_deg(low)
        if low_angle is not None:
            return low_angle, "basso"

    vertical = _estimate_horizontal_roll_deg_from_vertical_fld(img)
    if vertical is not None:
        return vertical, "verticale"
    return None


def _estimate_horizontal_roll_deg_fld(img: np.ndarray) -> float | None:
    """Stima roll con Fast Line Detector, scegliendo un cluster coerente."""
    lines = _detect_fld_lines(img)
    if not lines:
        return None

    h, w = img.shape[:2]
    horizontal = [(angle, length) for angle, length in lines if abs(angle) <= 25]
    best = _best_angle_cluster(
        horizontal,
        min_count=3,
        max_mad_deg=2.5,
        min_total_length=w * 0.35,
    )
    if best is None:
        return None
    return max(-20.0, min(20.0, best[1]))


def _estimate_horizontal_roll_deg_fld_orthogonal(img: np.ndarray) -> float | None:
    """Stima roll solo se FLD trova H e V coerenti quasi a 90 gradi."""
    lines = _detect_fld_lines(img)
    if not lines:
        return None

    h, w = img.shape[:2]
    horizontal = [(angle, length) for angle, length in lines if abs(angle) <= 25]
    vertical = [(angle, length) for angle, length in lines if abs(angle) >= 65]
    h_cluster = _best_angle_cluster(
        horizontal,
        min_count=3,
        max_mad_deg=2.5,
        min_total_length=w * 0.25,
    )
    v_cluster = _best_angle_cluster(
        vertical,
        min_count=3,
        max_mad_deg=3.5,
        min_total_length=h * 0.45,
    )
    if h_cluster is None or v_cluster is None:
        return None

    h_angle = h_cluster[1]
    v_angle = v_cluster[1]
    orthogonal_error = abs(abs(v_angle - h_angle) - 90.0)
    if orthogonal_error > 5.0:
        return None
    return max(-20.0, min(20.0, h_angle))


def _estimate_horizontal_roll_deg_from_vertical_fld(img: np.ndarray) -> float | None:
    """Stima il roll dalle sole verticali quando le orizzontali non bastano."""
    lines = _detect_fld_lines(img)
    if not lines:
        return None

    h, _ = img.shape[:2]
    vertical = [(angle, length) for angle, length in lines if abs(angle) >= 65]
    v_cluster = _best_angle_cluster(
        vertical,
        min_count=4,
        max_mad_deg=3.5,
        min_total_length=h * 0.55,
    )
    if v_cluster is None:
        return None

    v_angle = v_cluster[1]
    horizontal_equivalent = v_angle + 90.0 if v_angle < 0 else v_angle - 90.0
    return max(-20.0, min(20.0, horizontal_equivalent))


def _detect_fld_lines(img: np.ndarray) -> list[tuple[float, float]]:
    """Ritorna linee FLD come (angolo normalizzato, lunghezza) nel contenuto."""
    if not hasattr(cv2, "ximgproc") or not hasattr(cv2.ximgproc, "createFastLineDetector"):
        return []

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    mask = _content_mask(img)
    gray = cv2.bitwise_and(gray, gray, mask=(mask > 0.5).astype(np.uint8) * 255)
    h, w = gray.shape[:2]
    max_dim = max(h, w)
    scale = 1800.0 / max_dim if max_dim > 1800 else 1.0
    if scale < 1.0:
        gray_small = cv2.resize(gray, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    else:
        gray_small = gray

    detector = cv2.ximgproc.createFastLineDetector(
        length_threshold=45,
        distance_threshold=1.41421356,
        canny_th1=50,
        canny_th2=150,
        canny_aperture_size=3,
        do_merge=True,
    )
    detected = detector.detect(gray_small)
    if detected is None:
        return []

    inv = 1.0 / scale
    min_len = max(60.0, w * 0.055)
    lines: list[tuple[float, float]] = []
    for item in detected[:, 0, :]:
        x1, y1, x2, y2 = [float(v) * inv for v in item]
        dx = x2 - x1
        dy = y2 - y1
        length = math.hypot(dx, dy)
        if length < min_len:
            continue
        angle = math.degrees(math.atan2(dy, dx))
        while angle <= -90:
            angle += 180
        while angle > 90:
            angle -= 180
        if abs(angle) > 25 and abs(angle) < 65:
            continue
        mx = int(round((x1 + x2) * 0.5))
        my = int(round((y1 + y2) * 0.5))
        if not (0 <= mx < w and 0 <= my < h and mask[my, mx] > 0.5):
            continue
        lines.append((float(angle), float(length)))
    return lines


def _best_angle_cluster(
    lines: list[tuple[float, float]],
    *,
    min_count: int,
    max_mad_deg: float,
    min_total_length: float,
) -> tuple[float, float, list[tuple[float, float]]] | None:
    """Sceglie il cluster angolare più forte: (score, median_angle, cluster)."""
    if len(lines) < min_count:
        return None

    clusters: list[list[tuple[float, float]]] = []
    for line in sorted(lines, key=lambda item: item[0]):
        placed = False
        for cluster in clusters:
            median = float(np.median([item[0] for item in cluster]))
            if abs(line[0] - median) <= 3.0:
                cluster.append(line)
                placed = True
                break
        if not placed:
            clusters.append([line])

    best: tuple[float, float, list[tuple[float, float]]] | None = None
    for cluster in clusters:
        if len(cluster) < min_count:
            continue
        angles = np.array([item[0] for item in cluster], dtype=np.float64)
        lengths = np.array([item[1] for item in cluster], dtype=np.float64)
        median = float(np.median(angles))
        mad = float(np.median(np.abs(angles - median)))
        total_len = float(lengths.sum())
        if mad > max_mad_deg or total_len < min_total_length:
            continue
        score = total_len * max(0.2, 1.0 - mad / 5.0)
        if best is None or score > best[0]:
            best = (score, median, cluster)

    return best


@lru_cache(maxsize=1)
def _loftr_matcher():
    """Carica LoFTR solo se torch/kornia sono installati nell'ambiente."""
    import torch
    from kornia.feature import LoFTR

    matcher = LoFTR(pretrained="outdoor")
    matcher.eval()
    return matcher


def _resize_for_loftr(img: np.ndarray, max_side: int = 960) -> tuple[np.ndarray, float, float]:
    h, w = img.shape[:2]
    scale = min(float(max_side) / float(max(h, w)), 1.0)
    new_w = max(8, int(w * scale) // 8 * 8)
    new_h = max(8, int(h * scale) // 8 * 8)
    if new_w == w and new_h == h:
        return img, 1.0, 1.0
    resized = cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_AREA)
    return resized, w / float(new_w), h / float(new_h)


def _estimate_similarity_from_loftr(
    prev_top: np.ndarray,
    curr_bottom: np.ndarray,
    *,
    h_curr: int,
    h_overlap_curr: int,
) -> tuple[np.ndarray, float, float] | None:
    """Stima similarity con LoFTR sulle sole fasce di contatto.

    LoFTR è opzionale: se torch/kornia non sono installati, il chiamante passa
    ai matcher classici. La trasformazione accettata resta una similarity
    controllata, mai una omografia libera.
    """
    try:
        import torch
    except Exception:
        return None

    matcher = _loftr_matcher()
    prev_small, sx_prev, sy_prev = _resize_for_loftr(prev_top)
    curr_small, sx_curr, sy_curr = _resize_for_loftr(curr_bottom)
    g_prev = cv2.cvtColor(prev_small, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    g_curr = cv2.cvtColor(curr_small, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    data = {
        "image0": torch.from_numpy(g_prev)[None, None],
        "image1": torch.from_numpy(g_curr)[None, None],
    }
    with torch.inference_mode():
        matches = matcher(data)

    k_prev = matches["keypoints0"].detach().cpu().numpy()
    k_curr = matches["keypoints1"].detach().cpu().numpy()
    conf = matches["confidence"].detach().cpu().numpy()
    if len(k_prev) < 18:
        return None

    threshold = max(0.20, float(np.quantile(conf, 0.45)))
    keep = conf >= threshold
    k_prev = k_prev[keep]
    k_curr = k_curr[keep]
    if len(k_prev) < 18:
        return None

    dst = np.column_stack([k_prev[:, 0] * sx_prev, k_prev[:, 1] * sy_prev]).astype(np.float32)
    src_patch = np.column_stack([k_curr[:, 0] * sx_curr, k_curr[:, 1] * sy_curr]).astype(np.float32)
    src = src_patch.copy()
    src[:, 1] += h_curr - h_overlap_curr

    A, inliers = cv2.estimateAffinePartial2D(
        src,
        dst,
        method=cv2.RANSAC,
        ransacReprojThreshold=10.0,
        maxIters=5000,
        confidence=0.995,
    )
    if A is None or inliers is None:
        return None

    inlier_count = int(inliers.sum())
    inlier_ratio = inlier_count / max(1, len(k_prev))
    scale = float(np.sqrt(A[0, 0] ** 2 + A[1, 0] ** 2))
    rotation_deg = abs(math.degrees(math.atan2(float(A[1, 0]), float(A[0, 0]))))
    if inlier_count < 18 or inlier_ratio < 0.20:
        return None
    if not (0.55 <= scale <= 3.20):
        return None
    if rotation_deg > 10.0:
        return None

    A3 = np.vstack([A.astype(np.float64), [0.0, 0.0, 1.0]])
    response = float(min(1.0, inlier_ratio))
    return A3, response, scale


def _estimate_similarity_from_features(
    prev_top: np.ndarray,
    curr_bottom: np.ndarray,
    *,
    detector_name: str,
    h_curr: int,
    h_overlap_curr: int,
) -> tuple[np.ndarray, float, float] | None:
    """Stima similarity curr_bottom -> prev_top usando solo l'overlap vincolato."""
    g_prev = cv2.cvtColor(prev_top, cv2.COLOR_BGR2GRAY)
    g_curr = cv2.cvtColor(curr_bottom, cv2.COLOR_BGR2GRAY)

    if detector_name == "sift":
        if not hasattr(cv2, "SIFT_create"):
            return None
        detector = cv2.SIFT_create(nfeatures=2500, contrastThreshold=0.015)
        norm = cv2.NORM_L2
        ratio = 0.72
    elif detector_name == "akaze":
        detector = cv2.AKAZE_create()
        norm = cv2.NORM_HAMMING
        ratio = 0.78
    else:
        return None

    mask_prev = (_content_mask(prev_top) > 0.5).astype(np.uint8) * 255
    mask_curr = (_content_mask(curr_bottom) > 0.5).astype(np.uint8) * 255
    kp_prev, ds_prev = detector.detectAndCompute(g_prev, mask_prev)
    kp_curr, ds_curr = detector.detectAndCompute(g_curr, mask_curr)
    if ds_prev is None or ds_curr is None or len(kp_prev) < 10 or len(kp_curr) < 10:
        return None

    matcher = cv2.BFMatcher(norm)
    knn = matcher.knnMatch(ds_curr, ds_prev, k=2)
    good = []
    for pair in knn:
        if len(pair) != 2:
            continue
        a, b = pair
        if a.distance < ratio * b.distance:
            good.append(a)
    if len(good) < 8:
        return None

    src = np.float32([kp_curr[m.queryIdx].pt for m in good])
    dst = np.float32([kp_prev[m.trainIdx].pt for m in good])
    A, inliers = cv2.estimateAffinePartial2D(
        src,
        dst,
        method=cv2.RANSAC,
        ransacReprojThreshold=6.0,
        maxIters=5000,
        confidence=0.99,
    )
    if A is None or inliers is None:
        return None
    inlier_count = int(inliers.sum())
    inlier_ratio = inlier_count / max(1, len(good))
    scale = float(np.sqrt(A[0, 0] ** 2 + A[1, 0] ** 2))
    if not (0.60 <= scale <= 2.30 and inlier_count >= 7 and inlier_ratio >= 0.22):
        return None

    patch_to_full = np.array([
        [1.0, 0.0, 0.0],
        [0.0, 1.0, -(h_curr - h_overlap_curr)],
        [0.0, 0.0, 1.0],
    ], dtype=np.float64)
    A3 = np.vstack([A.astype(np.float64), [0.0, 0.0, 1.0]])
    M = A3 @ patch_to_full
    response = float(min(1.0, inlier_ratio))
    return M, response, scale


def _usable_content_bbox(img: np.ndarray) -> tuple[int, int, int, int] | None:
    """Bounding box della zona fotografica utile, ignorando bordi neri/triangoli."""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    mask = (gray > 10).astype(np.uint8)
    kernel = np.ones((7, 7), dtype=np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)

    h, w = mask.shape
    col_sum = mask.sum(axis=0)
    row_sum = mask.sum(axis=1)
    xs = np.where(col_sum >= max(8, int(h * 0.22)))[0]
    ys = np.where(row_sum >= max(8, int(w * 0.22)))[0]
    if len(xs) == 0 or len(ys) == 0:
        return None
    return int(xs[0]), int(ys[0]), int(xs[-1]), int(ys[-1])


def _match_strips(
    prev_strip: np.ndarray,
    curr_strip: np.ndarray,
    *,
    overlap_ratio: float,
    weak_threshold: float,
    prev_meta: Optional[dict] = None,
    curr_meta: Optional[dict] = None,
) -> tuple[float, float, float, str, Optional[str]]:
    """Trova offset (dx, dy) fra TOP overlap di `prev_strip` e BOTTOM overlap
    di `curr_strip`. Phase correlation primaria (su patch normalizzate alla
    stessa larghezza), ORB fallback su overlap, geometric fallback (Δpitch ×
    pixels/grado) se entrambi deboli.

    Returns:
      (dx, dy, response, method, warning_or_None)
    """
    h_prev, w_prev = prev_strip.shape[:2]
    h_curr, w_curr = curr_strip.shape[:2]
    h_overlap_prev = int(h_prev * overlap_ratio)
    h_overlap_curr = int(h_curr * overlap_ratio)
    prev_top    = prev_strip[:h_overlap_prev, :]
    curr_bottom = curr_strip[-h_overlap_curr:, :]

    # Normalizzazione: porto entrambe le patch alla stessa larghezza/altezza
    # (la più piccola) tramite resize. Il keystone-correct produce output di
    # scala diversa per pitch diversi; senza normalizzare phase corr falla.
    target_w = min(prev_top.shape[1], curr_bottom.shape[1])
    target_h = min(prev_top.shape[0], curr_bottom.shape[0])
    prev_norm = cv2.resize(prev_top,    (target_w, target_h), interpolation=cv2.INTER_AREA)
    curr_norm = cv2.resize(curr_bottom, (target_w, target_h), interpolation=cv2.INTER_AREA)
    # Tieni anche i fattori di scala per ricondurre i (dx,dy) trovati alle coords originali
    scale_x_prev = prev_top.shape[1] / float(target_w)
    scale_y_prev = prev_top.shape[0] / float(target_h)

    # Try phase correlation
    try:
        g_prev = cv2.cvtColor(prev_norm, cv2.COLOR_BGR2GRAY).astype(np.float32)
        g_curr = cv2.cvtColor(curr_norm, cv2.COLOR_BGR2GRAY).astype(np.float32)
        hann = cv2.createHanningWindow(g_prev.shape[::-1], cv2.CV_32F)
        (dx_n, dy_n), response = cv2.phaseCorrelate(g_prev * hann, g_curr * hann)
        # Riconduci alla scala originale di prev_strip
        dx = dx_n * scale_x_prev
        dy = dy_n * scale_y_prev
        if response >= weak_threshold:
            return float(dx), float(dy), float(response), "phase_correlation", None
        weak = f"phase_corr debole ({response:.2f}<{weak_threshold})"
    except Exception as e:
        weak = f"phase_corr eccezione: {e}"
        dx = dy = 0.0; response = 0.0

    # Fallback: ORB sull'overlap (più rumoroso ma a volte trova match dove pc fallisce)
    try:
        orb = cv2.ORB_create(nfeatures=500)
        g_prev_u8 = cv2.cvtColor(prev_norm, cv2.COLOR_BGR2GRAY)
        g_curr_u8 = cv2.cvtColor(curr_norm, cv2.COLOR_BGR2GRAY)
        kp1, ds1 = orb.detectAndCompute(g_prev_u8, None)
        kp2, ds2 = orb.detectAndCompute(g_curr_u8, None)
        if ds1 is not None and ds2 is not None and len(kp1) >= 8 and len(kp2) >= 8:
            bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
            matches = sorted(bf.match(ds1, ds2), key=lambda m: m.distance)[:30]
            if len(matches) >= 6:
                pts1 = np.float32([kp1[m.queryIdx].pt for m in matches])
                pts2 = np.float32([kp2[m.trainIdx].pt for m in matches])
                deltas = pts2 - pts1
                # Median più robusto della media in presenza di outlier
                dx_orb_n = float(np.median(deltas[:, 0]))
                dy_orb_n = float(np.median(deltas[:, 1]))
                # "response" proxy: inverso della varianza dei delta (più bassa = più coerenti)
                spread = float(np.median(np.linalg.norm(deltas - np.array([dx_orb_n, dy_orb_n]), axis=1)))
                response_orb = max(0.0, 1.0 - spread / 50.0)
                # L'offset qui è un residuo rispetto allo stacking ideale già
                # calcolato nel placement. Se ORB propone un salto grande quanto
                # l'intera fascia, sta matchando dettagli sbagliati.
                plausible_dx = abs(dx_orb_n) <= target_w * 0.35
                plausible_dy = abs(dy_orb_n) <= target_h * 0.45
                if response_orb > response and plausible_dx and plausible_dy:
                    return (dx_orb_n * scale_x_prev, dy_orb_n * scale_y_prev,
                            response_orb, "orb_fallback", weak)
    except Exception:
        pass

    # Geometric fallback: usa Δpitch + FOV per stimare dy (dx=0).
    # L'overlap zone è già accounted for nel placement (h_overlap), quindi dy
    # qui rappresenta lo SCOSTAMENTO RESIDUO rispetto al posizionamento ideale.
    # Se Δpitch è coerente con la dimensione di h_overlap rispetto al FOV,
    # dy ≈ 0 → restituiamo offset zero (= ideal stacking).
    dy_geom = 0.0
    dx_geom = 0.0
    return dx_geom, dy_geom, response, "geometric_fallback", weak + " → fallback geom"


def _feather_mask(shape: tuple[int, int], feather_px: int = 60) -> np.ndarray:
    """Mask alpha (HxW float32 in 0…1) con feather ai 4 bordi della strip."""
    h, w = shape
    feather_px = max(1, min(feather_px, min(h, w) // 2))
    mask = np.ones((h, w), dtype=np.float32)
    # Gradient da bordi al centro
    ramp = np.linspace(0.0, 1.0, feather_px, dtype=np.float32)
    for i in range(feather_px):
        mask[i, :]         = np.minimum(mask[i, :],         ramp[i])
        mask[h - 1 - i, :] = np.minimum(mask[h - 1 - i, :], ramp[i])
        mask[:, i]         = np.minimum(mask[:, i],         ramp[i])
        mask[:, w - 1 - i] = np.minimum(mask[:, w - 1 - i], ramp[i])
    return mask


def _content_mask(img: np.ndarray) -> np.ndarray:
    """Maschera i pixel reali, escludendo i triangoli neri generati dai warp."""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    mask = (gray > 8).astype(np.float32)
    # Chiudi piccoli buchi dovuti a dettagli molto scuri.
    kernel = np.ones((5, 5), dtype=np.uint8)
    mask_u8 = cv2.morphologyEx((mask * 255).astype(np.uint8), cv2.MORPH_CLOSE, kernel)
    return (mask_u8 > 0).astype(np.float32)


def _graphcut_multiband_blend(
    images: list[np.ndarray],
    masks: list[np.ndarray],
    corners: list[tuple[int, int]],
    canvas_w: int,
    canvas_h: int,
) -> np.ndarray:
    """Seam finding + multiband blending su immagini gia' nello stesso canvas."""
    if not images:
        return np.zeros((canvas_h, canvas_w, 3), dtype=np.uint8)
    if len(images) == 1:
        return images[0]

    seam_masks = [m.copy() for m in masks]
    seam_images = images
    seam_corners = corners
    seam_scale = 1.0
    max_dim = max(canvas_w, canvas_h)
    if max_dim > 1800:
        seam_scale = 1800.0 / float(max_dim)
        seam_size = (max(1, int(round(canvas_w * seam_scale))),
                     max(1, int(round(canvas_h * seam_scale))))
        seam_images = [cv2.resize(img, seam_size, interpolation=cv2.INTER_AREA) for img in images]
        seam_masks = [cv2.resize(m, seam_size, interpolation=cv2.INTER_NEAREST) for m in seam_masks]
        seam_corners = [(0, 0) for _ in seam_images]
    try:
        try:
            seam_finder = cv2.detail.GraphCutSeamFinder("COST_COLOR")
        except Exception:
            seam_finder = cv2.detail.GraphCutSeamFinder(cv2.detail.GraphCutSeamFinderBase_COST_COLOR)
        seam_masks = seam_finder.find([img.astype(np.float32) for img in seam_images], seam_corners, seam_masks)
    except Exception:
        try:
            seam_finder = cv2.detail.DpSeamFinder("COLOR")
            seam_masks = seam_finder.find(seam_images, seam_corners, seam_masks)
        except Exception:
            seam_masks = masks

    if seam_scale != 1.0 and seam_masks is not masks:
        seam_masks = [
            cv2.resize(m.get() if hasattr(m, "get") else m, (canvas_w, canvas_h), interpolation=cv2.INTER_NEAREST).astype(np.uint8)
            for m in seam_masks
        ]
    else:
        seam_masks = [(m.get() if hasattr(m, "get") else m).astype(np.uint8) for m in seam_masks]

    blender = cv2.detail.MultiBandBlender()
    blender.setNumBands(5)
    blender.prepare((0, 0, canvas_w, canvas_h))
    for img, mask in zip(images, seam_masks):
        blender.feed(img.astype(np.int16), mask.astype(np.uint8), (0, 0))
    result, result_mask = blender.blend(None, None)
    result = np.clip(result, 0, 255).astype(np.uint8)
    empty = result_mask == 0
    if empty.any():
        fallback = np.zeros_like(result)
        for img, mask in zip(images, masks):
            take = mask > 0
            fallback[take] = img[take]
        result[empty] = fallback[empty]
    return result
