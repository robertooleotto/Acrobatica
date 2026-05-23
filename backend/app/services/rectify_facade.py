"""Rettifica planare 2D di un panorama di facciata dato 4 punti del muro
principale (TL, TR, BR, BL).

Approccio: omografia 2D via `cv2.getPerspectiveTransform`. NON usa pose ARKit
e NON triangola in 3D. Lavora esclusivamente sui pixel del panorama già
stitched/composto.

Vantaggi vs il flusso 3D triangolato:
- robusto a drift ARKit, baseline insufficiente, elementi rientranti
- l'utente decide visualmente cosa è muro vero (no ambiguità: tap su 4 angoli
  ben distanti, sul muro principale)
- pochi fallimenti modali

Limite: l'aspect-ratio del rettangolo di destinazione è una stima euristica
(media dei lati). La scala metrica vera arriva da uno step successivo (2 tap +
distanza nota → meters/pixel).
"""
from __future__ import annotations
from dataclasses import dataclass, asdict
from typing import Optional

import cv2
import numpy as np


@dataclass(frozen=True)
class RectifyResult:
    """Output di rectify_quad_to_rect."""
    output_size: tuple[int, int]              # (W, H) px del risultato
    homography_3x3: list[list[float]]         # M usata in warpPerspective (src→dst)
    src_quad_px: list[tuple[float, float]]    # 4 punti input nel src
    dst_rect_px: list[tuple[float, float]]    # 4 corner del rettangolo destinazione

    def to_dict(self) -> dict:
        return asdict(self)


def _euclidean(a, b) -> float:
    return float(np.hypot(a[0] - b[0], a[1] - b[1]))


def estimate_aspect_from_quad(quad_px: list[tuple[float, float]]) -> tuple[float, float]:
    """Stima width × height del rettangolo destinazione come MEDIA dei lati.

    Input: quad in ordine TL, TR, BR, BL (4 punti src sul panorama).
    Output: (width_px, height_px) in unità arbitrarie ma con proporzioni
    sensate per l'aspect-ratio del muro reale.
    """
    if len(quad_px) != 4:
        raise ValueError("quad_px deve avere 4 punti TL, TR, BR, BL")
    TL, TR, BR, BL = quad_px
    top    = _euclidean(TL, TR)
    bottom = _euclidean(BL, BR)
    left   = _euclidean(TL, BL)
    right  = _euclidean(TR, BR)
    width  = (top + bottom) / 2.0
    height = (left + right) / 2.0
    return (width, height)


def validate_quad(quad_px: list[tuple[float, float]],
                  img_w: int, img_h: int,
                  min_side_frac: float = 0.10) -> Optional[str]:
    """Verifica che i 4 tap siano sensati. Ritorna None se OK, altrimenti
    una stringa con la spiegazione del problema.

    Controlli:
    - 4 punti, dentro l'immagine
    - lati minimi >= `min_side_frac` × min(W, H) del panorama (= punti non
      troppo vicini fra loro: l'errore di tap si propaga al risultato)
    - vertici disposti in ordine (TL alto-sinistra, TR alto-destra, BR basso-destra, BL basso-sinistra)
    """
    if len(quad_px) != 4:
        return "Servono esattamente 4 punti."
    for (x, y) in quad_px:
        if not (0 <= x <= img_w and 0 <= y <= img_h):
            return f"Punto ({x:.0f}, {y:.0f}) fuori dall'immagine ({img_w}×{img_h})."
    w, h = estimate_aspect_from_quad(quad_px)
    short = min(img_w, img_h) * min_side_frac
    if w < short or h < short:
        return (f"Quad troppo piccolo: lati medi {w:.0f}×{h:.0f}px, "
                f"minimo richiesto {short:.0f}px. Tappa punti più distanti.")
    # Ordine: TL.y, TR.y devono essere < BL.y, BR.y (in pixel y cresce verso il basso)
    TL, TR, BR, BL = quad_px
    if (TL[1] > BL[1] - short/2) or (TR[1] > BR[1] - short/2):
        return "I punti TL/TR sembrano sotto i BL/BR. Controlla l'ordine TL→TR→BR→BL."
    if (TL[0] > TR[0] - short/2) or (BL[0] > BR[0] - short/2):
        return "I punti TL/BL sembrano a destra dei TR/BR. Controlla l'ordine."
    return None


def rectify_quad_to_rect(
    img: np.ndarray,
    src_quad: list[tuple[float, float]],
    *,
    output_max_dim: int = 2400,
    aspect_override: Optional[float] = None,
) -> tuple[np.ndarray, RectifyResult]:
    """Calcola e applica l'omografia che mappa `src_quad` (4 punti TL/TR/BR/BL
    sul panorama) in un rettangolo dell'output.

    Args:
      img: panorama BGR (HxWx3).
      src_quad: 4 (x, y) in pixel del panorama.
      output_max_dim: clamp del lato più lungo dell'output.
      aspect_override: se dato, forza width/height del rettangolo di
        destinazione (es. dopo lo step "scala metrica" sapremo l'aspect vero).

    Returns:
      (immagine_rettificata, info)
    """
    if len(src_quad) != 4:
        raise ValueError("src_quad deve avere 4 punti TL, TR, BR, BL")

    w_est, h_est = estimate_aspect_from_quad(src_quad)
    if aspect_override is not None:
        if w_est >= h_est:
            h_est = w_est / aspect_override
        else:
            w_est = h_est * aspect_override

    out_w = int(round(w_est))
    out_h = int(round(h_est))
    # Clamp dimensione max conservando proporzioni
    if max(out_w, out_h) > output_max_dim:
        s = output_max_dim / max(out_w, out_h)
        out_w = max(1, int(round(out_w * s)))
        out_h = max(1, int(round(out_h * s)))

    src = np.asarray(src_quad, dtype=np.float32)
    dst = np.asarray([
        [0,        0],
        [out_w-1,  0],
        [out_w-1,  out_h-1],
        [0,        out_h-1],
    ], dtype=np.float32)

    M = cv2.getPerspectiveTransform(src, dst)
    rectified = cv2.warpPerspective(
        img, M, (out_w, out_h),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0),
    )
    info = RectifyResult(
        output_size=(out_w, out_h),
        homography_3x3=M.tolist(),
        src_quad_px=[(float(p[0]), float(p[1])) for p in src_quad],
        dst_rect_px=[(float(p[0]), float(p[1])) for p in dst.tolist()],
    )
    return rectified, info


# ────────────────────────── SCALA METRICA ──────────────────────────

def meters_per_pixel(p1_px: tuple[float, float],
                     p2_px: tuple[float, float],
                     distance_m: float) -> float:
    """Da 2 tap utente sull'immagine rettificata + distanza reale → m/px."""
    if distance_m <= 0:
        raise ValueError("distance_m deve essere > 0")
    d_px = _euclidean(p1_px, p2_px)
    if d_px < 1e-3:
        raise ValueError("I 2 tap sono troppo vicini fra loro")
    return float(distance_m / d_px)
