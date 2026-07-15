from pathlib import Path
from types import SimpleNamespace

import numpy as np

from app.services import oc_reference_bake
from app.services import ortho_bake
from scripts import run_oc_reference_registration_local as registration


def test_registration_budget_grows_with_real_plane_size():
    current_facade = SimpleNamespace(width_m=22.0, area_m2=416.0)
    larger_facade = SimpleNamespace(width_m=60.0, area_m2=1200.0)
    very_large_facade = SimpleNamespace(width_m=120.0, area_m2=3000.0)

    assert oc_reference_bake.adaptive_registration_budget(current_facade) == 12
    assert oc_reference_bake.adaptive_registration_budget(larger_facade) == 30
    assert oc_reference_bake.adaptive_registration_budget(very_large_facade) == 32


def test_registration_selection_exceeds_baseline_when_coverage_requires_it():
    frame = ortho_bake.PlaneFrame(
        origin=np.array([0.0, 0.0, 0.0]),
        u=np.array([1.0, 0.0, 0.0]),
        v=np.array([0.0, 1.0, 0.0]),
        corners=np.array([[0, 0, 0], [60, 0, 0], [60, 20, 0], [0, 20, 0]], float),
        polygon_uv=np.array([[0, 0], [60, 0], [60, 20], [0, 20]], float),
        width_world=60.0, height_world=20.0,
        width_m=60.0, height_m=20.0, area_m2=1200.0,
        tex_w=600, tex_h=200, texel_m=0.1,
    )
    cameras = [
        ortho_bake.Camera(
            key=str(index), C=np.array([x, 10.0, 10.0]), R=np.eye(3),
            fx=160.0, fy=160.0, cx=100.0, cy=200.0,
            image_width=200, image_height=400,
        )
        for index, x in enumerate(np.linspace(0.0, 60.0, 25))
    ]
    ranked = [
        {"key": camera.key, "score": float(len(cameras) - index)}
        for index, camera in enumerate(cameras)
    ]

    selected, report = oc_reference_bake._select_registration_candidates(
        frame, np.array([0.0, 0.0, 1.0]), cameras, ranked,
        crop=0.9, base_photos=12, max_photos=32,
    )

    assert report["budget"] == 30
    assert len(selected) > 12
    assert report["double_coverage"] >= 0.95


def test_diagnostic_overlay_accepts_an_empty_overlap():
    reference = np.full((12, 8, 3), 90, np.uint8)
    source = np.full((12, 8, 3), 220, np.uint8)

    output = registration._overlay(
        reference, source, np.zeros((12, 8), bool),
    )

    assert np.array_equal(output, reference)


def test_compose_plane_uses_registered_photo_and_preserves_alpha(monkeypatch, tmp_path):
    frame = ortho_bake.PlaneFrame(
        origin=np.array([0.0, 0.0, 0.0]),
        u=np.array([1.0, 0.0, 0.0]),
        v=np.array([0.0, 1.0, 0.0]),
        corners=np.array([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]], float),
        polygon_uv=np.array([[0, 0], [1, 0], [1, 1], [0, 1]], float),
        width_world=1.0, height_world=1.0,
        width_m=1.0, height_m=1.0, area_m2=1.0,
        tex_w=64, tex_h=64, texel_m=1 / 64,
    )
    camera = ortho_bake.Camera(
        key="0", C=np.array([0.0, 0.0, 1.0]), R=np.eye(3),
        fx=100.0, fy=100.0, cx=32.0, cy=32.0,
        image_width=64, image_height=64,
    )
    reference = np.full((64, 64, 4), 80, np.uint8)
    reference[..., 3] = 255
    source = np.zeros((64, 64, 3), np.uint8)
    source[..., 2] = 240
    mask = np.ones((64, 64), bool)
    identity = {
        "offset_x": 0.0, "offset_y": 0.0, "rotation_deg": 0.0, "scale": 1.0,
        "matrix": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    }

    monkeypatch.setattr(oc_reference_bake.registration, "orient_normal",
                        lambda *args: np.array([0.0, 0.0, 1.0]))
    monkeypatch.setattr(oc_reference_bake.registration, "orient_frame_for_front_view",
                        lambda *args: False)
    monkeypatch.setattr(oc_reference_bake.registration, "render_oc_reference",
                        lambda *args: (reference, mask, np.zeros((64, 64), np.float32)))
    monkeypatch.setattr(oc_reference_bake.registration, "rank_candidates",
                        lambda *args, **kwargs: [{"key": "0", "score": 1.0}])
    monkeypatch.setattr(oc_reference_bake.registration, "warp_photo_to_plane",
                        lambda *args: (source, mask))
    monkeypatch.setattr(oc_reference_bake.registration, "register_residual",
                        lambda *args, **kwargs: (source, mask, {"accepted": True}))
    monkeypatch.setattr(
        oc_reference_bake.registration, "global_align_photos",
        lambda images, masks, keys: (images, masks, {"applied": True}, [identity]),
    )

    rgba, coverage, used, report = oc_reference_bake._compose_plane(
        object(), frame, {"normale": [0, 0, 1]}, [camera],
        lambda key: str(tmp_path / "photo.jpg"),
        scale_m_per_mesh_unit=1.0, max_photos=1, registration_ceiling=4,
        coverage_photos=1,
        crop=0.9, depth_m=2.0, max_residual_px=40.0,
        max_rotation_deg=0.5, max_scale_error=0.03,
    )

    assert coverage == 1.0
    assert used == ["0"]
    assert report["registered_photos"] == 1
    assert np.all(rgba[..., 3] == 255)
    assert float(rgba[..., 2].mean()) == 240.0
