"""Test per stitching_service.

Costruiamo un'immagine sorgente sintetica con feature random (chiavi ORB ne trovano
molte), la croppiamo in due o tre tile sovrapposte, salviamo su disco, e verifichiamo
che lo stitcher la ricomponga.
"""
from __future__ import annotations
import tempfile
from pathlib import Path

import cv2
import numpy as np
import pytest

from app.services.stitching_service import orb_stitch, stitch_images


def _make_textured_image(w: int = 1200, h: int = 800, seed: int = 7) -> np.ndarray:
    """Immagine con texture random pesante (ORB ci trova migliaia di feature)."""
    rng = np.random.default_rng(seed)
    base = rng.integers(0, 255, size=(h, w, 3), dtype=np.uint8)
    # Aggiungiamo qualche rettangolo nero per dare strutture ben distinguibili.
    for _ in range(30):
        x, y = rng.integers(0, w - 50), rng.integers(0, h - 50)
        ww, hh = rng.integers(20, 80), rng.integers(20, 80)
        cv2.rectangle(base, (x, y), (x + ww, y + hh), (0, 0, 0), -1)
    return base


def _split_with_overlap(img: np.ndarray, n_tiles: int = 2, overlap: float = 0.3) -> list[np.ndarray]:
    """Spezza l'immagine in `n_tiles` tile orizzontali con overlap proporzionale."""
    h, w = img.shape[:2]
    tile_w = int(w / (n_tiles - (n_tiles - 1) * overlap))
    step = int(tile_w * (1 - overlap))
    tiles = []
    for i in range(n_tiles):
        x0 = i * step
        x1 = min(x0 + tile_w, w)
        tiles.append(img[:, x0:x1].copy())
    return tiles


def test_orb_stitch_two_tiles_recomposes_to_original_size():
    src = _make_textured_image(1600, 900)
    tiles = _split_with_overlap(src, n_tiles=2, overlap=0.3)
    result, info = orb_stitch(tiles)
    assert info["method"] == "orb"
    assert info["warning"] is None
    cw, ch = info["canvas_size"]
    # Il canvas dovrebbe avere larghezza vicino a quella dell'originale (entro ±15%).
    assert 0.85 * 1600 < cw < 1.15 * 1600, f"canvas width {cw} fuori range"
    # E altezza simile a quella dell'originale.
    assert 0.85 * 900 < ch < 1.15 * 900, f"canvas height {ch} fuori range"


def test_orb_stitch_three_tiles():
    src = _make_textured_image(2400, 800)
    tiles = _split_with_overlap(src, n_tiles=3, overlap=0.4)
    result, info = orb_stitch(tiles)
    assert info["method"] == "orb"
    assert info["warning"] is None
    assert info["n_photos"] == 3
    assert len(info["pair_stats"]) == 2
    for ps in info["pair_stats"]:
        # Dovremmo avere almeno 30 inlier RANSAC su immagini sintetiche con tanta texture.
        assert ps["inliers"] >= 30, f"troppi pochi inlier: {ps}"


def test_orb_stitch_too_few_features_returns_warning():
    # Due immagini grigio uniforme: ORB non troverà feature.
    blank = np.full((400, 400, 3), 128, dtype=np.uint8)
    result, info = orb_stitch([blank, blank])
    assert info["method"] == "orb_failed"
    assert info["warning"] is not None


def test_stitch_images_via_files(tmp_path: Path):
    src = _make_textured_image(1600, 900)
    tiles = _split_with_overlap(src, n_tiles=2, overlap=0.3)
    paths = []
    for i, t in enumerate(tiles):
        p = tmp_path / f"tile_{i}.jpg"
        cv2.imwrite(str(p), t)
        paths.append(str(p))
    result, info = stitch_images(paths)
    # cv2.Stitcher PANORAMA potrebbe fallire (texture random, no scene 3D coerente):
    # accettiamo sia il successo del PANORAMA che il fallback ORB.
    assert info["method"] in {"panorama", "orb"}
    assert info["n_photos"] == 2
