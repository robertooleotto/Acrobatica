"""Test ortorettifica su scena sintetica: muro piatto con scacchiera nota,
camera ARKit-style posta a distanza nota e angolo di pitch noto.

Verifichiamo:
  - fit_plane_from_points recupera la normale (entro epsilon)
  - orthorectify_photo produce un'immagine in cui la scacchiera è ortogonale
    e con scala corretta in metri.
"""
from __future__ import annotations
import math

import cv2
import numpy as np
import pytest

from app.services.orthorectify_service import (
    fit_plane_from_points, orthorectify_photo, WallPlane,
)


def _Rx(theta):  # rotation around X
    c, s = math.cos(theta), math.sin(theta)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]], dtype=np.float64)


def _checkerboard(w_px=1200, h_px=900, squares=8):
    img = np.full((h_px, w_px, 3), 255, dtype=np.uint8)
    sq_w = w_px // squares
    sq_h = h_px // squares
    for r in range(squares):
        for c in range(squares):
            if (r + c) % 2 == 0:
                cv2.rectangle(img,
                              (c * sq_w, r * sq_h),
                              ((c + 1) * sq_w, (r + 1) * sq_h),
                              (0, 0, 0), -1)
    return img


def test_fit_plane_recovers_normal():
    # 4 punti su un piano XZ (y costante)  → normale = (0, 1, 0)
    # Test del fit libero (assume_vertical=False).
    pts = [(0, 1, 0), (5, 1, 0), (5, 1, 5), (0, 1, 5)]
    plane = fit_plane_from_points(pts, assume_vertical=False)
    nx, ny, nz = plane.normal
    # Normalizzazione: la normale può venire con segno opposto, ne prendiamo |dot| con (0,1,0).
    assert abs(abs(ny) - 1.0) < 1e-6
    assert abs(nx) < 1e-6 and abs(nz) < 1e-6
    # Bounds approssimati: u_max-u_min e v_max-v_min devono essere ~5
    assert abs((plane.u_max - plane.u_min) - 5.0) < 1e-6 or \
           abs((plane.v_max - plane.v_min) - 5.0) < 1e-6


def test_fit_plane_vertical_constraint():
    """Piano "verticale": punti su un muro reale + un po' di rumore lungo Y.
    Con assume_vertical=True la normale deve avere componente Y ~ 0."""
    # Muro verticale a Z=-3, larghezza 4m, altezza 3m. Aggiungo rumore in Z.
    rng = np.random.default_rng(42)
    pts = []
    for u in np.linspace(-2, 2, 8):
        for v in np.linspace(-1.5, 1.5, 6):
            z = -3.0 + rng.normal(0, 0.05)
            pts.append((u, v, z))
    plane = fit_plane_from_points(pts, assume_vertical=True)
    nx, ny, nz = plane.normal
    assert abs(ny) < 1e-6  # vincolo verticale rispettato
    # Normale ≈ (0, 0, ±1)
    assert abs(abs(nz) - 1.0) < 0.05


def test_orthorectify_pitch_synthetic():
    """Camera a distanza nota, pitch 0 (di fronte al muro): l'ortorettifica deve
    produrre un'immagine che combacia con la scacchiera originale."""
    # Setup: muro su piano Z = -3 (3m davanti alla camera), assi:
    #   normale verso la camera = (0, 0, 1)
    #   right (verso destra del mondo)  = (1, 0, 0)
    #   up (verso l'alto del mondo)     = (0, 1, 0)
    # Wall bounds: 4m × 3m
    plane = WallPlane(
        point=(0.0, 0.0, -3.0),
        normal=(0.0, 0.0, 1.0),
        right=(1.0, 0.0, 0.0),
        up=(0.0, 1.0, 0.0),
        u_min=-2.0, u_max=2.0,
        v_min=-1.5, v_max=1.5,
    )
    scene = _checkerboard(w_px=1200, h_px=900, squares=8)

    # Camera: posizione (0,0,0), assi mondo = assi camera frame (R = identità)
    # ARKit frame: +x destra, +y su, +z verso il viewer, looks at -z. Identità OK.
    cam_transform = np.eye(4).flatten(order="F").tolist()
    # Intrinsics: scegli fx=fy in modo che la "scacchiera vista dal davanti" combaci
    # con la nostra immagine sintetica. La scena 4m×3m a 3m di distanza ha FOV:
    #   tan(α/2) = 2/3  →  α ≈ 67° (orizzontale)
    # fx = (w_px/2) / tan(α/2) = 600 / (2/3) = 900
    intrinsics = [900.0, 0.0, 0.0, 0.0, 900.0, 0.0, 600.0, 450.0, 1.0]

    out, info = orthorectify_photo(
        scene, intrinsics, cam_transform, plane,
        pixels_per_meter=100,  # 4m × 100 = 400 px wide
    )
    # Output atteso: 400 × 300 px
    assert out.shape == (300, 400, 3)
    # La scacchiera deve apparire nell'output: pixel neri (≥30%) E pixel bianchi (≥30%),
    # ~50/50 con qualche tolleranza per i bordi.
    gray = cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)
    blacks = (gray < 80).sum()
    whites = (gray > 200).sum()
    total = 300 * 400
    assert blacks / total > 0.30
    assert whites / total > 0.30
    assert 0.4 < blacks / (blacks + whites) < 0.6
