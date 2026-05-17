"""Test di integrazione del flusso completo API: create → upload x2 → process → result."""
from __future__ import annotations
import io
import json
from pathlib import Path

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.utils import image_io


@pytest.fixture
def client(tmp_path, monkeypatch):
    # Isola lo storage in tmp_path per non sporcare la dir di sviluppo.
    monkeypatch.setattr(image_io, "DATA_ROOT", tmp_path)
    return TestClient(app)


def _textured_tile_bytes(w: int = 1200, h: int = 800, seed: int = 42) -> bytes:
    rng = np.random.default_rng(seed)
    img = rng.integers(0, 255, size=(h, w, 3), dtype=np.uint8)
    for _ in range(40):
        x, y = rng.integers(0, w - 60), rng.integers(0, h - 60)
        cv2.rectangle(img, (x, y), (x + 50, y + 50), (0, 0, 0), -1)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 90])
    assert ok
    return buf.tobytes()


def _metadata_for(order_index: int, w: int = 1200, h: int = 800) -> str:
    return json.dumps({
        "order_index": order_index,
        "timestamp": 1000.0 + order_index,
        # Identity camera pose; intrinsics neutre.
        "camera_transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
        "camera_intrinsics": [1500,0,0, 0,1500,0, w/2,h/2,1],
        "euler_angles": [0.0, 0.0, 0.0],
        "tracking_state": "normal",
        "image_width": w,
        "image_height": h,
    })


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_full_flow_create_upload_process_result(client):
    # 1) Create session
    r = client.post("/facade-sessions")
    assert r.status_code == 201
    sid = r.json()["session_id"]

    # 2) Upload 2 tile sovrapposte (sintetiche).
    rng = np.random.default_rng(0)
    base = rng.integers(0, 255, size=(800, 1600, 3), dtype=np.uint8)
    for _ in range(60):
        x, y = rng.integers(0, 1500), rng.integers(0, 700)
        cv2.rectangle(base, (x, y), (x + 50, y + 50), (0, 0, 0), -1)
    left = base[:, :1000]
    right = base[:, 600:]

    for idx, img in enumerate([left, right]):
        ok, buf = cv2.imencode(".jpg", img)
        assert ok
        files = {"image": (f"tile_{idx}.jpg", buf.tobytes(), "image/jpeg")}
        data = {"metadata": _metadata_for(idx, img.shape[1], img.shape[0])}
        r = client.post(f"/facade-sessions/{sid}/photos", files=files, data=data)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["order_index"] == idx
        assert body["photos_count"] == idx + 1

    # 3) Process
    r = client.post(f"/facade-sessions/{sid}/process", json={})
    assert r.status_code == 200, r.text
    res = r.json()
    assert res["gross_area_pixels"] > 0
    assert res["net_area_pixels"] >= 0
    # m² non viene calcolato senza scaleFactor → assenti.
    assert res["gross_area_m2"] is None
    assert res["net_area_m2"] is None
    assert res["stitched_url"] is not None

    # 4) Result re-fetch
    r = client.get(f"/facade-sessions/{sid}/result")
    assert r.status_code == 200
    assert r.json()["stitched_url"] == res["stitched_url"]

    # 5) File served
    fname = res["stitched_url"].split("/")[-1]
    r = client.get(f"/facade-sessions/{sid}/files/{fname}")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("image/")


def test_process_with_facade_quad_pixels_rectifies(client):
    r = client.post("/facade-sessions")
    sid = r.json()["session_id"]

    # Una foto sola → il "panorama" coincide con la foto.
    img_bytes = _textured_tile_bytes(1200, 800)
    files = {"image": ("p.jpg", img_bytes, "image/jpeg")}
    data = {"metadata": _metadata_for(0, 1200, 800)}
    r = client.post(f"/facade-sessions/{sid}/photos", files=files, data=data)
    assert r.status_code == 200

    # Forniamo un quadrilatero (trapezio sintetico) come quad del muro.
    quad = [[100, 100], [1100, 150], [1050, 700], [150, 650]]
    r = client.post(f"/facade-sessions/{sid}/process", json={"facade_quad_pixels": quad})
    assert r.status_code == 200, r.text
    res = r.json()
    assert res["rectified_url"] is not None
    assert res["facade_polygon"] is not None
    # Il facade_polygon restituito è il rettangolo destinazione, lo stesso del quad warpato.
    assert len(res["facade_polygon"]) == 4


def test_scale_factor_converts_pixels_to_m2(client):
    r = client.post("/facade-sessions")
    sid = r.json()["session_id"]
    files = {"image": ("p.jpg", _textured_tile_bytes(800, 600), "image/jpeg")}
    data = {"metadata": _metadata_for(0, 800, 600)}
    client.post(f"/facade-sessions/{sid}/photos", files=files, data=data)
    # Scala: 0.01 m/px → 1 cm/px → 800x600 px = 8x6 m = 48 m².
    r = client.post(f"/facade-sessions/{sid}/process", json={"scale_factor_meters_per_pixel": 0.01})
    assert r.status_code == 200
    res = r.json()
    assert res["gross_area_m2"] is not None
    assert abs(res["gross_area_m2"] - 48.0) < 0.5  # tolleranza per rettifica/canvas
