"""Calcolo aree facciata: lorda, esclusioni, netta. In pixel quadrati.

Conversione in m² solo se viene fornito uno `scale_factor_m_per_px`.
"""
from __future__ import annotations
from typing import Optional

import numpy as np

from ..models import Opening


def measure(
    rectified_image: np.ndarray,
    openings: list[Opening],
    scale_factor_m_per_px: Optional[float] = None,
) -> dict:
    h, w = rectified_image.shape[:2]
    gross_px = float(w * h)
    excluded_px = sum(o.area_pixels for o in openings)
    net_px = max(gross_px - excluded_px, 0.0)

    out: dict = {
        "gross_area_pixels": gross_px,
        "excluded_area_pixels": excluded_px,
        "net_area_pixels": net_px,
    }
    if scale_factor_m_per_px is not None and scale_factor_m_per_px > 0:
        s2 = scale_factor_m_per_px ** 2
        out["gross_area_m2"] = gross_px * s2
        out["net_area_m2"] = net_px * s2
    return out
