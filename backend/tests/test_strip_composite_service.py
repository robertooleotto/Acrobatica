from __future__ import annotations

import numpy as np

from app.services import strip_composite_service as svc
from app.services.strip_composite_service import group_metadata_into_columns


def _meta(order: int, pitch: float, tx: float, tz: float = 0.0) -> dict:
    transform = [0.0] * 16
    transform[0] = transform[5] = transform[10] = transform[15] = 1.0
    transform[12] = tx
    transform[14] = tz
    return {
        "order_index": order,
        "euler_angles": [pitch, 0.0, 0.0],
        "camera_transform": transform,
    }


def test_group_metadata_into_columns_detects_pitch_resets():
    metadata = [
        _meta(0, -2.0, 0.0),
        _meta(2, 42.0, 0.0),
        _meta(3, -1.0, -2.4),
        _meta(4, 16.0, -2.4),
        _meta(5, 31.0, -2.4),
        _meta(6, 56.0, -2.4),
        _meta(7, -2.0, -5.5),
        _meta(8, 20.0, -5.5),
    ]

    groups = group_metadata_into_columns(metadata)

    assert [g.order_indices for g in groups] == [
        [0, 2],
        [3, 4, 5, 6],
        [7, 8],
    ]
    assert "pitch_reset" in groups[1].reason


def test_horizontal_roll_prefers_global_orthogonal_before_low_fallback(monkeypatch):
    img = np.zeros((400, 480, 3), dtype=np.uint8)

    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg_fld_orthogonal", lambda _img: 2.25)
    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg_fld", lambda _crop: 4.0)
    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg", lambda _crop: None)

    assert svc._estimate_horizontal_roll_deg_preferred_bands(img) == (2.25, "ortogonale")


def test_horizontal_roll_uses_only_low_band_when_orthogonal_pair_is_missing(monkeypatch):
    img = np.zeros((400, 480, 3), dtype=np.uint8)
    calls = {"low_fld": 0}

    def fake_low_fld(_crop):
        calls["low_fld"] += 1
        return 3.5

    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg_fld_orthogonal", lambda _crop: None)
    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg_fld", fake_low_fld)
    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg", lambda _crop: None)

    assert svc._estimate_horizontal_roll_deg_preferred_bands(img) == (3.5, "basso")
    assert calls["low_fld"] == 1


def test_horizontal_roll_uses_vertical_when_orthogonal_and_low_fail(monkeypatch):
    img = np.zeros((400, 480, 3), dtype=np.uint8)

    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg_fld_orthogonal", lambda _img: None)
    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg_fld", lambda _crop: None)
    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg", lambda _crop: None)
    monkeypatch.setattr(svc, "_estimate_horizontal_roll_deg_from_vertical_fld", lambda _img: -1.75)

    assert svc._estimate_horizontal_roll_deg_preferred_bands(img) == (-1.75, "verticale")
