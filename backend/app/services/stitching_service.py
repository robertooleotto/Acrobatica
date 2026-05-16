"""Stitching delle foto in un mosaico unico.

Strategia:
  1. cv2.Stitcher_create(PANORAMA) come tentativo principale.
  2. Se fallisce (tipicamente con scatti ravvicinati di facciate dove l'algoritmo
     non riesce a stimare il modello di camera sferico), passa al fallback custom:
     ORB → BFMatcher(crossCheck) → cv2.findHomography(RANSAC) → cv2.warpPerspective
     con blending "last-wins" su canvas dimensionato al bounding box dei corner warpati.

L'output è un'immagine BGR (OpenCV); il chiamante la salva via `save_image`.
"""
from __future__ import annotations
from pathlib import Path
from typing import Optional

import cv2
import numpy as np


def stitch_images(image_paths: list[str]) -> tuple[np.ndarray, dict]:
    """Tenta lo stitching e restituisce (immagine, info_debug)."""
    if not image_paths:
        raise ValueError("image_paths vuoto")

    images: list[np.ndarray] = []
    for p in image_paths:
        img = cv2.imread(p)
        if img is not None:
            images.append(img)

    if len(images) == 0:
        raise ValueError("Nessuna immagine leggibile")
    if len(images) == 1:
        return images[0], {"method": "single", "n_photos": 1, "warning": None}

    # 1) Tentativo con cv2.Stitcher PANORAMA.
    stitcher = cv2.Stitcher_create(cv2.Stitcher_PANORAMA)
    status, pano = stitcher.stitch(images)
    if status == cv2.Stitcher_OK and pano is not None:
        return pano, {"method": "panorama", "n_photos": len(images), "warning": None}

    # 2) Fallback ORB+findHomography.
    return orb_stitch(images, primary_status=status)


def orb_stitch(images: list[np.ndarray], primary_status: Optional[int] = None) -> tuple[np.ndarray, dict]:
    """Stitch tramite ORB feature matching + omografie pairwise concatenate.

    La prima immagine è il "frame di riferimento" del mosaico. Le successive sono
    allineate a quella precedente; le omografie vengono composte per portare tutto
    nel frame della prima.
    """
    if len(images) < 2:
        return images[0], {"method": "orb_single", "n_photos": len(images), "warning": None}

    orb = cv2.ORB_create(nfeatures=5000)
    keypoints: list = []
    descriptors: list = []
    for img in images:
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        kp, des = orb.detectAndCompute(gray, None)
        if des is None or len(kp) < 50:
            return images[0], {
                "method": "orb_failed",
                "n_photos": len(images),
                "warning": f"Troppi pochi feature ORB in una delle foto ({len(kp) if kp else 0})",
                "primary_status": primary_status,
            }
        keypoints.append(kp)
        descriptors.append(des)

    bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
    homographies: list[np.ndarray] = [np.eye(3, dtype=np.float64)]  # H_0 → H_0 = identity
    pair_stats: list[dict] = []

    for i in range(1, len(images)):
        matches = bf.match(descriptors[i], descriptors[i - 1])
        matches = sorted(matches, key=lambda m: m.distance)
        # Limita ai 500 match migliori per stabilità RANSAC.
        matches = matches[:500]
        if len(matches) < 8:
            return images[0], {
                "method": "orb_failed",
                "n_photos": len(images),
                "warning": f"Solo {len(matches)} match tra foto {i - 1} e {i} (min 8)",
                "primary_status": primary_status,
                "pair_stats": pair_stats,
            }
        src = np.float32([keypoints[i][m.queryIdx].pt for m in matches]).reshape(-1, 1, 2)
        dst = np.float32([keypoints[i - 1][m.trainIdx].pt for m in matches]).reshape(-1, 1, 2)
        H_pair, mask = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
        if H_pair is None:
            return images[0], {
                "method": "orb_failed",
                "n_photos": len(images),
                "warning": f"findHomography fallita su coppia ({i - 1},{i})",
                "primary_status": primary_status,
                "pair_stats": pair_stats,
            }
        inliers = int(mask.sum()) if mask is not None else 0
        pair_stats.append({"pair": [i - 1, i], "matches": len(matches), "inliers": inliers})
        H_to_ref = homographies[i - 1] @ H_pair
        homographies.append(H_to_ref)

    # Calcola il bounding box del canvas (warpando i 4 angoli di ogni immagine).
    all_corners: list[np.ndarray] = []
    for i, img in enumerate(images):
        h, w = img.shape[:2]
        corners = np.float32([[0, 0], [w, 0], [w, h], [0, h]]).reshape(-1, 1, 2)
        all_corners.append(cv2.perspectiveTransform(corners, homographies[i]))
    pts = np.concatenate(all_corners, axis=0).reshape(-1, 2)
    xmin, ymin = np.floor(pts.min(axis=0)).astype(int)
    xmax, ymax = np.ceil(pts.max(axis=0)).astype(int)
    canvas_w = int(xmax - xmin)
    canvas_h = int(ymax - ymin)

    # Sanity check: clamp a una dimensione ragionevole per evitare panorami giganti
    # in caso di omografie degenerate.
    MAX_DIM = 12000
    if canvas_w > MAX_DIM or canvas_h > MAX_DIM or canvas_w <= 0 or canvas_h <= 0:
        return images[0], {
            "method": "orb_failed",
            "n_photos": len(images),
            "warning": f"Canvas dimensione anomala {canvas_w}x{canvas_h} (omografie probabilmente degenerate)",
            "primary_status": primary_status,
            "pair_stats": pair_stats,
        }

    translation = np.array([[1, 0, -xmin], [0, 1, -ymin], [0, 0, 1]], dtype=np.float64)
    canvas = np.zeros((canvas_h, canvas_w, 3), dtype=np.uint8)

    for i, img in enumerate(images):
        H_final = translation @ homographies[i]
        warped = cv2.warpPerspective(img, H_final, (canvas_w, canvas_h))
        # Blend "last-wins": ogni immagine successiva ricopre i pixel non vuoti.
        # Per blending feathered/multi-band si veda issue futuro.
        mask = (warped.sum(axis=2) > 0)
        canvas[mask] = warped[mask]

    return canvas, {
        "method": "orb",
        "n_photos": len(images),
        "canvas_size": [canvas_w, canvas_h],
        "primary_status": primary_status,
        "pair_stats": pair_stats,
        "warning": None,
    }


def save_image(img: np.ndarray, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out_path), img, [cv2.IMWRITE_JPEG_QUALITY, 90])
