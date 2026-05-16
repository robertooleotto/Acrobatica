"""Rettifica prospettica della facciata.

Modalita supportate:
  - rectify_from_quad(img, quad): 4 punti del muro forniti dal client → omografia → rettangolo
  - rectify_automatic(img):       Canny + HoughLinesP → vanishing points → quad → rettifica

Per ora `rectify` chiama il primo se quad è fornito, altrimenti ritorna l'immagine così com'è
con un warning (l'automatica arriva nella prossima iterazione).
"""
from __future__ import annotations
from pathlib import Path
from typing import Optional

import cv2
import numpy as np

Quad = list[tuple[float, float]]


def rectify(img: np.ndarray, quad: Optional[Quad] = None) -> tuple[np.ndarray, dict]:
    """Restituisce (immagine_rettificata, info)."""
    if quad and len(quad) == 4:
        return rectify_from_quad(img, quad)
    return img, {"warning": "Rettifica automatica non ancora implementata; immagine non rettificata"}


def rectify_from_quad(img: np.ndarray, quad: Quad) -> tuple[np.ndarray, dict]:
    """Trasforma il quadrilatero sorgente in un rettangolo.

    quad: 4 punti pixel in ordine TL, TR, BR, BL.
    Le dimensioni del rettangolo destinazione sono stimate dalle distanze sui lati.
    """
    if len(quad) != 4:
        raise ValueError("quad richiede esattamente 4 punti")

    src = np.array(quad, dtype=np.float32)
    tl, tr, br, bl = src
    width = max(np.linalg.norm(tr - tl), np.linalg.norm(br - bl))
    height = max(np.linalg.norm(bl - tl), np.linalg.norm(br - tr))
    w_out = int(round(width))
    h_out = int(round(height))

    dst = np.array([
        [0, 0],
        [w_out - 1, 0],
        [w_out - 1, h_out - 1],
        [0, h_out - 1],
    ], dtype=np.float32)

    H = cv2.getPerspectiveTransform(src, dst)
    rectified = cv2.warpPerspective(img, H, (w_out, h_out))
    return rectified, {
        "facade_polygon": [(0.0, 0.0), (float(w_out - 1), 0.0), (float(w_out - 1), float(h_out - 1)), (0.0, float(h_out - 1))],
        "vanishing_points": None,
        "homography": H.tolist(),
    }


def save_image(img: np.ndarray, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out_path), img, [cv2.IMWRITE_JPEG_QUALITY, 90])
