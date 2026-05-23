"""Test rettifica planare 2D da 4 punti."""
from __future__ import annotations

import cv2
import numpy as np
import pytest

from app.services.rectify_facade import (
    estimate_aspect_from_quad,
    validate_quad,
    rectify_quad_to_rect,
    meters_per_pixel,
)


def _make_target_image(w=1200, h=900):
    """Sfondo grigio con griglia di linee nere ortogonali — perfetto per
    verificare se la rettifica produce vera ortogonalità."""
    img = np.full((h, w, 3), 200, dtype=np.uint8)
    for x in range(0, w, 100): cv2.line(img, (x, 0), (x, h-1), (0,0,0), 2)
    for y in range(0, h, 100): cv2.line(img, (0, y), (w-1, y), (0,0,0), 2)
    cv2.rectangle(img, (50, 50), (w-50, h-50), (0,0,0), 4)
    return img


def test_estimate_aspect_basic():
    quad = [(0, 0), (100, 0), (100, 50), (0, 50)]
    w, h = estimate_aspect_from_quad(quad)
    assert abs(w - 100) < 1e-6
    assert abs(h - 50) < 1e-6


def test_validate_quad_ok():
    assert validate_quad([(100, 50), (900, 50), (900, 700), (100, 700)], 1000, 750) is None


def test_validate_quad_too_small():
    msg = validate_quad([(0, 0), (10, 0), (10, 10), (0, 10)], 1000, 750)
    assert msg is not None and "troppo piccolo" in msg


def test_validate_quad_wrong_order():
    # TL e BL invertiti
    msg = validate_quad([(100, 700), (900, 700), (900, 50), (100, 50)], 1000, 750)
    assert msg is not None


def test_rectify_inverts_known_homography():
    """Costruiamo un'immagine "distorta" applicando un'omografia a una griglia
    nota. La rectify_quad_to_rect coi 4 angoli della distorsione deve riportare
    una griglia ortogonale."""
    orig = _make_target_image(1200, 900)
    # Omografia di "skew" (top-right tirato in alto, top-left abbassato → trapezoide)
    h_perp = np.array([
        [1, 0.10, 0],
        [0.05, 1, 0],
        [0.0001, 0.0001, 1],
    ], dtype=np.float64)
    # Bounding box di output dopo l'applicazione
    src_corners = np.array([[0,0,1],[1200,0,1],[1200,900,1],[0,900,1]], dtype=np.float64).T
    out_c = h_perp @ src_corners; out_c /= out_c[2]
    xmin, xmax = out_c[0].min(), out_c[0].max()
    ymin, ymax = out_c[1].min(), out_c[1].max()
    T = np.array([[1,0,-xmin],[0,1,-ymin],[0,0,1]], dtype=np.float64)
    M_full = T @ h_perp
    out_w_dist = int(np.ceil(xmax - xmin))
    out_h_dist = int(np.ceil(ymax - ymin))
    distorted = cv2.warpPerspective(orig, M_full, (out_w_dist, out_h_dist))

    # I 4 "punti del muro" nel distorted = dove sono finiti i 4 angoli originali
    new_corners = (M_full @ src_corners); new_corners /= new_corners[2]
    quad = [(float(new_corners[0,i]), float(new_corners[1,i])) for i in range(4)]
    # ordine TL, TR, BR, BL già rispettato (sono i 4 angoli del rettangolo originale)

    rectified, info = rectify_quad_to_rect(distorted, quad)

    # Output ha dimensione attesa (≈ 1200×900 ± clamp)
    assert info.output_size[0] > 800 and info.output_size[1] > 600

    # Le linee verticali del rectified devono essere veramente verticali:
    # canny + houghlines, controllo che le pendenze siano ≈ 0 (pixel/pixel)
    gray = cv2.cvtColor(rectified, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 50, 150)
    lines = cv2.HoughLinesP(edges, 1, np.pi/360, threshold=80,
                            minLineLength=150, maxLineGap=10)
    assert lines is not None
    vert_slopes = []
    for l in lines:
        x1,y1,x2,y2 = l[0]
        if abs(y2-y1) > abs(x2-x1):  # linea verticale-ish
            vert_slopes.append(abs((x2-x1)/max(1,(y2-y1))))
    if vert_slopes:
        mean_slope = float(np.mean(vert_slopes))
        assert mean_slope < 0.05, f"verticali ancora storte: slope={mean_slope:.3f}"


def test_meters_per_pixel():
    mpp = meters_per_pixel((100, 100), (200, 100), 1.0)
    assert abs(mpp - 0.01) < 1e-9   # 100 px = 1 m → 0.01 m/px
    with pytest.raises(ValueError):
        meters_per_pixel((100, 100), (100, 100), 1.0)
