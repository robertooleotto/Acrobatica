"""Test sanità del modulo arkit_planar_stitch.

Scenario: 2 camere virtuali che guardano un "muro" piatto di texture sintetica
(rettangolo 4x3 metri davanti alla camera). Per ogni camera generiamo l'immagine
proiettando il muro col modello pinhole, poi diamo le pose come input al planar
stitch. Verifichiamo che l'output sia un'immagine non vuota con dimensioni circa
proporzionali al muro reale (~4m × 3m).
"""
from __future__ import annotations
import math

import cv2
import numpy as np
import pytest

from app.services.arkit_planar_stitch import (
    CameraPose, FacadePlane, arkit_planar_stitch
)


def _make_wall_texture(w_px: int = 1600, h_px: int = 1200, seed: int = 12) -> np.ndarray:
    rng = np.random.default_rng(seed)
    img = rng.integers(0, 255, size=(h_px, w_px, 3), dtype=np.uint8)
    for _ in range(80):
        x, y = rng.integers(0, w_px - 100), rng.integers(0, h_px - 100)
        cv2.rectangle(img, (x, y), (x + 80, y + 80), (0, 0, 0), -1)
    return img


def _pose_at(x: float, y: float, z: float, fx: float = 1500, w: int = 1920, h: int = 1440) -> CameraPose:
    """Camera che guarda lungo -Z dal punto (x, y, z) (frame ARKit canonico)."""
    return CameraPose(
        transform=[
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, z, 1,
        ],
        intrinsics=[fx, 0, 0, 0, fx, 0, w / 2, h / 2, 1],
    )


def _project_wall_to_image(wall_tex: np.ndarray, wall_w_m: float, wall_h_m: float,
                            wall_z: float, pose: CameraPose, img_w: int, img_h: int) -> np.ndarray:
    """Genera l'immagine vista dalla camera proiettando un muro piatto col modello pinhole."""
    # 4 corner del muro in world space, piano z = wall_z.
    half_w, half_h = wall_w_m / 2, wall_h_m / 2
    corners_world = np.array([
        [-half_w,  half_h, wall_z],  # TL
        [ half_w,  half_h, wall_z],  # TR
        [ half_w, -half_h, wall_z],  # BR
        [-half_w, -half_h, wall_z],  # BL
    ], dtype=np.float64)
    # Proiettali nei pixel della camera.
    K = pose.intrinsics
    fx, fy, cx, cy = K[0], K[4], K[6], K[7]
    cam_pos = np.array(pose.transform[12:15], dtype=np.float64)
    img_pts = []
    for cw in corners_world:
        dx, dy, dz = cw - cam_pos
        # ARKit camera: image y down, world y up → flip y
        u = cx + fx * (dx / -dz)
        v = cy - fy * (dy / -dz)
        img_pts.append([u, v])
    img_pts = np.array(img_pts, dtype=np.float32)
    # Texture corners (TL, TR, BR, BL).
    th, tw = wall_tex.shape[:2]
    tex_pts = np.array([[0, 0], [tw - 1, 0], [tw - 1, th - 1], [0, th - 1]], dtype=np.float32)
    H = cv2.getPerspectiveTransform(tex_pts, img_pts)
    warped = cv2.warpPerspective(wall_tex, H, (img_w, img_h))
    return warped


def test_arkit_planar_stitch_recovers_planar_facade():
    wall_tex = _make_wall_texture(1600, 1200)
    wall_w_m, wall_h_m, wall_z = 4.0, 3.0, -3.0  # muro 4×3m, 3m davanti
    img_w, img_h = 1920, 1440

    pose_left = _pose_at(-0.8, 0, 0, fx=1500, w=img_w, h=img_h)
    pose_right = _pose_at( 0.8, 0, 0, fx=1500, w=img_w, h=img_h)

    img_left = _project_wall_to_image(wall_tex, wall_w_m, wall_h_m, wall_z, pose_left, img_w, img_h)
    img_right = _project_wall_to_image(wall_tex, wall_w_m, wall_h_m, wall_z, pose_right, img_w, img_h)

    plane = FacadePlane(origin=(0, 0, wall_z), normal=(0, 0, 1))  # piano z=-3, normale +z (verso camera)
    result, info = arkit_planar_stitch([img_left, img_right], [pose_left, pose_right], plane,
                                        px_per_m=200.0)

    assert info["method"] == "arkit_planar"
    assert info["warning"] is None
    # La canvas deve coprire un'area che include il muro 4×3m. Tolleranza ±20%.
    w_m, h_m = info["width_m"], info["height_m"]
    assert w_m >= 3.0, f"width_m={w_m} troppo stretta"
    assert h_m >= 2.4, f"height_m={h_m} troppo bassa"
    # Almeno il 50% del canvas deve essere coperto.
    assert info["coverage_percent"] > 50, f"coverage troppo bassa: {info['coverage_percent']:.1f}%"
