"""Stitching planare ARKit-guidato (strada C).

Pipeline:
  Per ogni foto i abbiamo:
    - immagine I_i (HxW pixel)
    - camera_transform T_i (4x4 col-major, ARKit camera→world)
    - camera_intrinsics K_i (3x3 col-major, fx fy cx cy)
    - piano facciata: punto sul piano P0 (world) + normale n (world unitaria)

  Per ognuna calcoliamo l'omografia H_i che mappa pixel immagine → coordinate (u, v)
  in metri sul piano della facciata (sistema 2D del piano), e da lì → pixel canvas
  ortofoto a scala costante.

  Output: ortofoto unica RGB con dimensioni in metri note (px_per_m fisso),
  niente fisheye/distorsione cilindrica.

NB:
  - Questo modulo è uno *scaffold*: la math è scritta ma il blending è semplice.
  - Va validato con foto reali con baseline > 30cm + piano facciata correttamente stimato.
  - Fallback manuale a 4 punti: gestito dal router (`rectification_service.rectify_from_quad`).
"""
from __future__ import annotations
import math
from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class CameraPose:
    """Pose + intrinsics di una foto. transform e intrinsics in col-major."""
    transform: list[float]   # 16 floats (camera→world)
    intrinsics: list[float]  # 9 floats (K = [[fx,0,0],[0,fy,0],[cx,cy,1]])


@dataclass(frozen=True)
class FacadePlane:
    """Piano della facciata in coordinate mondo ARKit."""
    origin: tuple[float, float, float]
    normal: tuple[float, float, float]


def _t_pos(T: list[float]) -> np.ndarray:
    return np.array([T[12], T[13], T[14]], dtype=np.float64)


def _t_rot(T: list[float]) -> np.ndarray:
    """Upper-left 3x3 di T (col-major)."""
    return np.array([
        [T[0], T[4], T[8]],
        [T[1], T[5], T[9]],
        [T[2], T[6], T[10]],
    ], dtype=np.float64)


def _intrinsics_K(K: list[float]) -> np.ndarray:
    """Da col-major 9-float a matrice 3x3 standard."""
    return np.array([
        [K[0], 0,    K[6]],
        [0,    K[4], K[7]],
        [0,    0,    1.0],
    ], dtype=np.float64)


def _plane_basis(n: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Da una normale al piano, costruisce una base 2D (u, v) sul piano.
    Convenzione: v = proiezione di world-up sul piano (verticale lungo il muro),
    u = n × v (orizzontale lungo il muro), così u/v sono ortonormali e l'ortofoto
    avrà "up" del muro = up del mondo.
    """
    up = np.array([0.0, 1.0, 0.0])
    v_raw = up - np.dot(up, n) * n
    if np.linalg.norm(v_raw) < 1e-6:
        # Piano orizzontale degenerato — usa axis arbitrario.
        v_raw = np.array([0.0, 0.0, 1.0]) - np.dot(np.array([0.0, 0.0, 1.0]), n) * n
    v = v_raw / np.linalg.norm(v_raw)
    u = np.cross(n, v)
    u = u / np.linalg.norm(u)
    return u, v


def pixel_to_plane_uv(pixel: tuple[float, float], pose: CameraPose, plane: FacadePlane,
                       u_axis: np.ndarray, v_axis: np.ndarray) -> tuple[float, float] | None:
    """Per un pixel (px, py), calcola raggio nel mondo, interseca col piano facciata,
    proietta sulle coordinate (u, v) in metri del piano. None se ray parallelo al piano."""
    K = _intrinsics_K(pose.intrinsics)
    R = _t_rot(pose.transform)
    o = _t_pos(pose.transform)
    fx, fy, cx, cy = K[0, 0], K[1, 1], K[0, 2], K[1, 2]
    px, py = pixel
    # Direzione in frame camera (ARKit guarda lungo -Z).
    dx_cam = (px - cx) / fx
    dy_cam = -(py - cy) / fy
    dz_cam = -1.0
    d_cam = np.array([dx_cam, dy_cam, dz_cam])
    d_cam /= np.linalg.norm(d_cam)
    d_world = R @ d_cam
    # Interseca col piano: t tale che dot(o + t*d - P0, n) = 0 → t = dot(P0 - o, n) / dot(d, n)
    n = np.array(plane.normal)
    P0 = np.array(plane.origin)
    denom = float(np.dot(d_world, n))
    if abs(denom) < 1e-6:
        return None
    t = float(np.dot(P0 - o, n) / denom)
    if t <= 0:
        return None
    p_world = o + t * d_world
    delta = p_world - P0
    u = float(np.dot(delta, u_axis))
    v = float(np.dot(delta, v_axis))
    return (u, v)


def homography_image_to_canvas(
    image_w: int, image_h: int,
    pose: CameraPose, plane: FacadePlane,
    u_axis: np.ndarray, v_axis: np.ndarray,
    u_min: float, v_max: float, px_per_m: float
) -> np.ndarray | None:
    """Omografia 3x3 che mappa pixel sorgente → pixel canvas ortofoto.
    Calcola la trasformazione dai 4 corner dell'immagine: ogni corner → punto 3D sul piano →
    coordinate (u, v) → pixel canvas. Poi `cv2.getPerspectiveTransform` per la H finale.
    """
    corners_src = np.array([
        [0, 0],
        [image_w - 1, 0],
        [image_w - 1, image_h - 1],
        [0, image_h - 1],
    ], dtype=np.float32)
    corners_dst = []
    for c in corners_src:
        uv = pixel_to_plane_uv((float(c[0]), float(c[1])), pose, plane, u_axis, v_axis)
        if uv is None:
            return None
        u, v = uv
        # Canvas: x = (u - u_min) * px_per_m, y = (v_max - v) * px_per_m (flip su Y per "up = up")
        x_canvas = (u - u_min) * px_per_m
        y_canvas = (v_max - v) * px_per_m
        corners_dst.append([x_canvas, y_canvas])
    corners_dst = np.array(corners_dst, dtype=np.float32)
    H = cv2.getPerspectiveTransform(corners_src, corners_dst)
    return H


def arkit_planar_stitch(
    images: list[np.ndarray],
    poses: list[CameraPose],
    plane: FacadePlane,
    px_per_m: float = 200.0,
    max_canvas_dim: int = 4096,
) -> tuple[np.ndarray, dict]:
    """Costruisce l'ortofoto planare della facciata.

    Per ogni foto: omografia dall'immagine alla canvas (proiettata sul piano), poi warp.
    Blending semplice "last-wins" con mask di copertura. Output BGR.
    """
    if len(images) == 0:
        raise ValueError("Nessuna immagine")
    if len(images) != len(poses):
        raise ValueError(f"Conta immagini ({len(images)}) != pose ({len(poses)})")

    n = np.array(plane.normal, dtype=np.float64)
    n = n / np.linalg.norm(n)
    u_axis, v_axis = _plane_basis(n)

    # 1) Calcola bounding box (u, v) di tutti i 4 corner di tutte le foto.
    u_min, u_max, v_min, v_max = math.inf, -math.inf, math.inf, -math.inf
    per_photo_corners: list[list[tuple[float, float]]] = []
    for img, pose in zip(images, poses):
        h, w = img.shape[:2]
        corners_uv: list[tuple[float, float]] = []
        for px, py in [(0, 0), (w - 1, 0), (w - 1, h - 1), (0, h - 1)]:
            uv = pixel_to_plane_uv((px, py), pose, plane, u_axis, v_axis)
            if uv is None:
                return images[0], {
                    "method": "arkit_planar_failed",
                    "warning": "Una foto ha un corner con ray parallelo al piano",
                    "n_photos": len(images),
                }
            corners_uv.append(uv)
            u_min = min(u_min, uv[0]); u_max = max(u_max, uv[0])
            v_min = min(v_min, uv[1]); v_max = max(v_max, uv[1])
        per_photo_corners.append(corners_uv)

    width_m = u_max - u_min
    height_m = v_max - v_min
    if width_m <= 0 or height_m <= 0:
        return images[0], {"method": "arkit_planar_failed", "warning": "Bounding box degenerato"}

    # 2) Clamp risoluzione canvas per evitare immagini gigantesche.
    px_per_m_eff = float(px_per_m)
    while int(width_m * px_per_m_eff) > max_canvas_dim or int(height_m * px_per_m_eff) > max_canvas_dim:
        px_per_m_eff *= 0.75
    canvas_w = max(int(width_m * px_per_m_eff), 1)
    canvas_h = max(int(height_m * px_per_m_eff), 1)
    canvas = np.zeros((canvas_h, canvas_w, 3), dtype=np.uint8)
    coverage = np.zeros((canvas_h, canvas_w), dtype=np.uint8)

    # 3) Per ogni foto: warpPerspective sul canvas, blend last-wins (pixel non-vuoti vincono).
    for img, pose in zip(images, poses):
        h, w = img.shape[:2]
        H = homography_image_to_canvas(w, h, pose, plane, u_axis, v_axis,
                                        u_min, v_max, px_per_m_eff)
        if H is None:
            continue
        warped = cv2.warpPerspective(img, H, (canvas_w, canvas_h))
        mask = (warped.sum(axis=2) > 0)
        canvas[mask] = warped[mask]
        coverage[mask] = 255

    coverage_pct = float(coverage.sum() / 255.0 / (canvas_w * canvas_h) * 100.0)

    return canvas, {
        "method": "arkit_planar",
        "n_photos": len(images),
        "warning": None,
        "canvas_size": [canvas_w, canvas_h],
        "width_m": width_m,
        "height_m": height_m,
        "px_per_m": px_per_m_eff,
        "coverage_percent": coverage_pct,
    }
