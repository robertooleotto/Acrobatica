"""Test keystone su scena sintetica con linee verticali note."""
from __future__ import annotations
import math

import cv2
import numpy as np

from app.services.keystone_correction import keystone_correct


def _make_vertical_lines_image(w: int = 1600, h: int = 1200) -> np.ndarray:
    img = np.full((h, w, 3), 200, dtype=np.uint8)
    n_lines = 8
    for i in range(n_lines):
        x = int((i + 1) * w / (n_lines + 1))
        cv2.line(img, (x, 50), (x, h - 50), (0, 0, 0), 6)
    cv2.rectangle(img, (100, 80), (w - 100, h - 80), (0, 0, 0), 4)
    return img


def _Rx(theta_rad: float) -> np.ndarray:
    c, s = math.cos(theta_rad), math.sin(theta_rad)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]], dtype=np.float64)


def _make_K(w: int, h: int, fx: float = 1500.0) -> np.ndarray:
    return np.array([[fx, 0, w/2], [0, fx, h/2], [0, 0, 1.0]], dtype=np.float64)


def _K_flat(K: np.ndarray) -> list[float]:
    return [
        float(K[0,0]), 0.0, 0.0,
        0.0, float(K[1,1]), 0.0,
        float(K[0,2]), float(K[1,2]), 1.0,
    ]


def _transform_flat(R: np.ndarray, t=(0.0, 0.0, 0.0)) -> list[float]:
    T = np.eye(4, dtype=np.float64)
    T[:3, :3] = R
    T[:3, 3] = t
    return T.flatten(order="F").tolist()


def _measure_vertical_lines_slope(img: np.ndarray) -> float:
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 50, 150)
    lines = cv2.HoughLinesP(edges, 1, np.pi/360, threshold=80,
                            minLineLength=200, maxLineGap=10)
    if lines is None:
        return 999
    slopes = []
    for line in lines:
        x1, y1, x2, y2 = line[0]
        if abs(y2 - y1) < 50:
            continue
        slope = abs((x2 - x1) / (y2 - y1))
        if slope < 0.5:
            slopes.append(slope)
    return float(np.mean(slopes)) if slopes else 999


def test_keystone_corrects_pitch_20deg():
    """Camera con pitch +20°: capture = scena · K·Rx(pitch)·K⁻¹.
    keystone con transform = Rx(pitch) deve riportare slope ≈ 0."""
    original = _make_vertical_lines_image(1600, 1200)
    K = _make_K(1600, 1200, fx=1500.0)
    pitch = math.radians(20.0)

    # Simulazione: per produrre l'immagine "vista da una camera tilted-up di pitch"
    # a partire da una scena "level", proiettiamo con K·Rx(-pitch)·K⁻¹.
    # (Un world-point che proietta a p_level nella scena, proietta a
    # K·Rx(-pitch)·K⁻¹·p_level nella camera ruotata di +pitch.)
    H_real = K @ _Rx(-pitch) @ np.linalg.inv(K)
    h, w = original.shape[:2]
    corners = np.array([[0,0,1],[w,0,1],[w,h,1],[0,h,1]], dtype=np.float64).T
    warped_corners = H_real @ corners
    warped_corners /= warped_corners[2]
    xmin, ymin = warped_corners[0].min(), warped_corners[1].min()
    xmax, ymax = warped_corners[0].max(), warped_corners[1].max()
    T = np.array([[1,0,-xmin],[0,1,-ymin],[0,0,1.0]])
    captured = cv2.warpPerspective(original, T @ H_real, (int(xmax-xmin), int(ymax-ymin)))

    slope_before = _measure_vertical_lines_slope(captured)
    assert slope_before > 0.10, f"Capture senza keystone effect (slope={slope_before})"

    h_cap, w_cap = captured.shape[:2]
    K_cap = _make_K(w_cap, h_cap, fx=1500.0)
    rectified, info = keystone_correct(
        captured, _K_flat(K_cap),
        camera_transform=_transform_flat(_Rx(pitch)),
    )
    slope_after = _measure_vertical_lines_slope(rectified)
    assert slope_after < 0.05, (
        f"before={slope_before:.3f} after={slope_after:.3f}"
    )
    assert not info.pre_rotated_cw
    assert not info.used_wall_normal


def test_keystone_no_op_when_camera_level():
    img = _make_vertical_lines_image(800, 600)
    K = _make_K(800, 600)
    out, info = keystone_correct(
        img, _K_flat(K),
        camera_transform=_transform_flat(np.eye(3)),
    )
    assert abs(out.shape[1] - 800) <= 2
    assert abs(out.shape[0] - 600) <= 2
    diff = cv2.absdiff(img, out)
    assert diff.mean() < 5.0
    assert not info.pre_rotated_cw


def test_keystone_pre_rotates_when_buffer_is_portrait():
    """Buffer portrait + metadata landscape → ruota 90° CW prima del warp."""
    img = _make_vertical_lines_image(800, 600)
    K = _make_K(800, 600)
    portrait = cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)  # 600×800
    out, info = keystone_correct(
        portrait, _K_flat(K),
        camera_transform=_transform_flat(np.eye(3)),
        metadata_image_size=(800, 600),
    )
    assert info.pre_rotated_cw
    assert out.shape[1] >= out.shape[0]


def test_keystone_uses_wall_normal_when_provided():
    img = _make_vertical_lines_image(800, 600)
    K = _make_K(800, 600)
    _, info = keystone_correct(
        img, _K_flat(K),
        camera_transform=_transform_flat(np.eye(3)),
        wall_normal_world=[0.0, 0.0, 1.0],
    )
    assert info.used_wall_normal
