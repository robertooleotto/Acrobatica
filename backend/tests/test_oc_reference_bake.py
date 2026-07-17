from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np

from app.services import oc_reference_bake
from app.services import ortho_bake
from scripts import run_oc_reference_registration_local as registration


def test_registration_budget_grows_with_real_plane_size():
    current_facade = SimpleNamespace(width_m=22.0, area_m2=416.0)
    larger_facade = SimpleNamespace(width_m=60.0, area_m2=1200.0)
    very_large_facade = SimpleNamespace(width_m=120.0, area_m2=3000.0)

    assert oc_reference_bake.adaptive_registration_budget(current_facade) == 30
    assert oc_reference_bake.adaptive_registration_budget(larger_facade) == 30
    assert oc_reference_bake.adaptive_registration_budget(very_large_facade) == 75


def test_mosaic_anchor_prefers_coverage_when_scores_are_nearly_tied():
    ranked = [
        {"key": "156", "score": 0.903595, "coverage": 0.3787, "facing": 0.6016},
        {"key": "135", "score": 0.902618, "coverage": 0.4911, "facing": 0.5333},
        {"key": "136", "score": 0.891600, "coverage": 0.5067, "facing": 0.5223},
        {"key": "other", "score": 0.80, "coverage": 0.90, "facing": 0.70},
    ]

    anchor = oc_reference_bake._stable_mosaic_anchor(
        ["156", "135", "136", "other"], ranked,
    )

    assert anchor == "135"


def test_mosaic_anchor_keeps_clearly_better_scored_photo():
    ranked = [
        {"key": "best", "score": 1.0, "coverage": 0.40, "facing": 0.70},
        {"key": "wide", "score": 0.90, "coverage": 0.80, "facing": 0.60},
    ]

    assert oc_reference_bake._stable_mosaic_anchor(
        ["best", "wide"], ranked,
    ) == "best"


def test_major_seam_refinement_applies_only_to_large_extension(monkeypatch):
    shape = (100, 100)
    anchor = np.zeros((*shape, 3), np.uint8)
    source = np.zeros_like(anchor)
    source[:, 40:] = 180
    anchor_mask = np.zeros(shape, bool)
    anchor_mask[:, :70] = True
    source_mask = np.zeros(shape, bool)
    source_mask[:, 40:] = True

    matrix = np.float64([[1.0, 0.0, -2.0], [0.0, 1.0, 0.0]])

    def accepted_affine(*_args):
        return matrix, {"accepted": True, "reason": "ok"}

    monkeypatch.setattr(
        oc_reference_bake, "_estimate_planar_seam_affine", accepted_affine,
    )
    images, planar, full, reports = oc_reference_bake._refine_major_seams(
        [anchor, source], [anchor_mask, source_mask],
        [anchor_mask, source_mask], ["anchor", "extension"],
    )

    assert reports == [{
        "accepted": True,
        "reason": "ok",
        "key": "extension",
        "new_pixels_before": 3_000,
    }]
    assert np.array_equal(images[0], anchor)
    assert full[1][:, 38].all()
    assert not full[1][:, 98].any()
    assert planar[1][:, 38].all()


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


def test_rejected_registration_is_not_reused_as_pose_filler():
    ranked = [{"key": str(index), "score": 10 - index} for index in range(5)]

    fillers = list(oc_reference_bake._pose_filler_candidates(
        ranked,
        attempted_keys={"0", "1", "2"},
        accepted_keys={"0", "2"},
        limit=5,
    ))

    assert [item[1]["key"] for item in fillers] == ["3", "4"]


def test_compose_plane_expands_until_registered_graph_is_connected(
    monkeypatch, tmp_path,
):
    frame = ortho_bake.PlaneFrame(
        origin=np.array([0.0, 0.0, 0.0]),
        u=np.array([1.0, 0.0, 0.0]),
        v=np.array([0.0, 1.0, 0.0]),
        corners=np.array([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]], float),
        polygon_uv=np.array([[0, 0], [1, 0], [1, 1], [0, 1]], float),
        width_world=1.0, height_world=1.0,
        width_m=1.0, height_m=1.0, area_m2=1.0,
        tex_w=100, tex_h=100, texel_m=0.01,
    )
    cameras = [
        ortho_bake.Camera(
            key=str(index), C=np.array([0.0, 0.0, 1.0]), R=np.eye(3),
            fx=100.0, fy=100.0, cx=50.0, cy=50.0,
            image_width=100, image_height=100,
        )
        for index in range(4)
    ]
    ranked = [{"key": str(index), "score": 4.0 - index} for index in range(4)]
    reference = np.full((100, 100, 4), 80, np.uint8)
    reference[..., 3] = 255
    source = np.full((100, 100, 3), 160, np.uint8)
    mask = np.ones((100, 100), bool)
    identity = {
        "offset_x": 0.0, "offset_y": 0.0, "rotation_deg": 0.0, "scale": 1.0,
        "matrix": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    }
    global_counts = []

    monkeypatch.setattr(oc_reference_bake.registration, "orient_normal",
                        lambda *args: np.array([0.0, 0.0, 1.0]))
    monkeypatch.setattr(oc_reference_bake.registration, "orient_frame_for_front_view",
                        lambda *args: False)
    monkeypatch.setattr(oc_reference_bake.registration, "render_oc_reference",
                        lambda *args: (reference, mask, np.zeros((100, 100), np.float32)))
    monkeypatch.setattr(oc_reference_bake.registration, "rank_candidates",
                        lambda *args, **kwargs: ranked)
    monkeypatch.setattr(oc_reference_bake, "_select_registration_candidates",
                        lambda *args, base_photos, **kwargs: (
                            ranked[:base_photos],
                            {"budget": base_photos, "selected": min(base_photos, 4)},
                        ))
    monkeypatch.setattr(oc_reference_bake.registration, "warp_photo_to_plane",
                        lambda *args: (source, mask))
    monkeypatch.setattr(oc_reference_bake.registration, "register_residual",
                        lambda *args, **kwargs: (source, mask, {"accepted": True}))

    def fake_global_align(images, masks, keys):
        global_counts.append(len(keys))
        components = [[key] for key in keys] if len(keys) < 4 else [keys]
        return images, masks, {
            "applied": True,
            "components": components,
            "pairs_accepted": max(0, len(keys) - len(components)),
        }, [identity for _ in keys]

    monkeypatch.setattr(
        oc_reference_bake.registration, "global_align_photos", fake_global_align,
    )

    _, coverage, used, report = oc_reference_bake._compose_plane(
        object(), frame, {"normale": [0, 0, 1]}, cameras,
        lambda key: str(tmp_path / f"{key}.jpg"),
        scale_m_per_mesh_unit=1.0, max_photos=2, registration_ceiling=4,
        coverage_photos=4, crop=0.9, depth_m=2.0, max_residual_px=40.0,
        max_rotation_deg=0.5, max_scale_error=0.03,
    )

    assert global_counts == [2, 4]
    assert coverage == 1.0
    assert used == ["0", "1", "2", "3"]
    assert report["registration_selection"]["rounds"][-1]["connected"] is True
    assert report["registration_selection"]["stop_reason"] == \
        "copertura e componente dominante sufficienti"


def test_compose_plane_uses_registered_photo_and_preserves_alpha(monkeypatch, tmp_path):
    frame = ortho_bake.PlaneFrame(
        origin=np.array([0.0, 0.0, 0.0]),
        u=np.array([1.0, 0.0, 0.0]),
        v=np.array([0.0, 1.0, 0.0]),
        corners=np.array([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]], float),
        polygon_uv=np.array([[0, 0], [1, 0], [1, 1], [0, 1]], float),
        width_world=1.0, height_world=1.0,
        width_m=1.0, height_m=1.0, area_m2=1.0,
        tex_w=100, tex_h=100, texel_m=0.01,
    )
    camera = ortho_bake.Camera(
        key="0", C=np.array([0.0, 0.0, 1.0]), R=np.eye(3),
        fx=100.0, fy=100.0, cx=50.0, cy=50.0,
        image_width=100, image_height=100,
    )
    reference = np.full((100, 100, 4), 80, np.uint8)
    reference[..., 3] = 255
    source = np.zeros((100, 100, 3), np.uint8)
    source[..., 2] = 240
    mask = np.ones((100, 100), bool)
    identity = {
        "offset_x": 0.0, "offset_y": 0.0, "rotation_deg": 0.0, "scale": 1.0,
        "matrix": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    }

    monkeypatch.setattr(oc_reference_bake.registration, "orient_normal",
                        lambda *args: np.array([0.0, 0.0, 1.0]))
    monkeypatch.setattr(oc_reference_bake.registration, "orient_frame_for_front_view",
                        lambda *args: False)
    monkeypatch.setattr(oc_reference_bake.registration, "render_oc_reference",
                        lambda *args: (reference, mask, np.zeros((100, 100), np.float32)))
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


def test_pose_filler_feathers_across_registered_photo_boundary(
    monkeypatch, tmp_path,
):
    frame = ortho_bake.PlaneFrame(
        origin=np.array([0.0, 0.0, 0.0]),
        u=np.array([1.0, 0.0, 0.0]),
        v=np.array([0.0, 1.0, 0.0]),
        corners=np.array([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]], float),
        polygon_uv=np.array([[0, 0], [1, 0], [1, 1], [0, 1]], float),
        width_world=1.0, height_world=1.0,
        width_m=1.0, height_m=1.0, area_m2=1.0,
        tex_w=100, tex_h=100, texel_m=0.01,
    )
    cameras = [
        ortho_bake.Camera(
            key=str(index), C=np.array([0.0, 0.0, 1.0]), R=np.eye(3),
            fx=100.0, fy=100.0, cx=50.0, cy=50.0,
            image_width=100, image_height=100,
        )
        for index in range(2)
    ]
    reference = np.full((100, 100, 4), 80, np.uint8)
    reference[..., 3] = 255
    registered = np.full((100, 100, 3), 60, np.uint8)
    filler = np.full((100, 100, 3), 220, np.uint8)
    registered_mask = np.zeros((100, 100), bool)
    registered_mask[:, :75] = True
    full_mask = np.ones((100, 100), bool)
    identity = {
        "offset_x": 0.0, "offset_y": 0.0, "rotation_deg": 0.0, "scale": 1.0,
        "matrix": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    }

    monkeypatch.setattr(oc_reference_bake.registration, "orient_normal",
                        lambda *args: np.array([0.0, 0.0, 1.0]))
    monkeypatch.setattr(oc_reference_bake.registration, "orient_frame_for_front_view",
                        lambda *args: False)
    monkeypatch.setattr(oc_reference_bake.registration, "render_oc_reference",
                        lambda *args: (reference, full_mask,
                                       np.zeros((100, 100), np.float32)))
    ranked = [{"key": "0", "score": 2.0}, {"key": "1", "score": 1.0}]
    monkeypatch.setattr(oc_reference_bake.registration, "rank_candidates",
                        lambda *args, **kwargs: ranked)
    monkeypatch.setattr(
        oc_reference_bake, "_select_registration_candidates",
        lambda *args, **kwargs: (ranked[:1], {"budget": 1, "selected": 1}),
    )

    def fake_warp(_path, camera, _frame):
        if camera.key == "0":
            return registered, registered_mask
        return filler, full_mask

    monkeypatch.setattr(oc_reference_bake.registration, "warp_photo_to_plane", fake_warp)
    monkeypatch.setattr(
        oc_reference_bake.registration, "register_residual",
        lambda *args, **kwargs: (registered, registered_mask, {"accepted": True}),
    )
    monkeypatch.setattr(
        oc_reference_bake.registration, "global_align_photos",
        lambda images, masks, keys: (
            images, masks, {"applied": True, "components": [["0"]]}, [identity],
        ),
    )
    monkeypatch.setattr(oc_reference_bake.registration, "photo_coverage_mask",
                        lambda *args: full_mask)

    rgba, coverage, used, report = oc_reference_bake._compose_plane(
        object(), frame, {"normale": [0, 0, 1]}, cameras,
        lambda key: str(tmp_path / f"{key}.jpg"),
        scale_m_per_mesh_unit=1.0, max_photos=1, registration_ceiling=1,
        coverage_photos=2, crop=0.9, depth_m=2.0, max_residual_px=40.0,
        max_rotation_deg=0.5, max_scale_error=0.03,
    )

    assert coverage == 1.0
    assert used == ["0", "1"]
    assert np.all(rgba[:, :65, :3] == 60)
    # The compositor also applies its bounded color correction (-18 here).
    assert np.all(rgba[:, 85:, :3] == 202)
    assert np.all((rgba[:, 70:75, :3] > 60) & (rgba[:, 70:75, :3] < 202))
    filler_report = next(item for item in report["photos"] if item["key"] == "1")
    assert filler_report["registration"]["gap_only"] is False
    assert filler_report["registration"]["coverage_pixels"] == 10_000


def test_opencv_bgra_texture_is_written_without_swapping_red_and_blue(tmp_path):
    texture = np.zeros((4, 5, 4), np.uint8)
    texture[..., 0] = 17
    texture[..., 1] = 83
    texture[..., 2] = 231
    texture[..., 3] = 255
    path = tmp_path / "texture.png"

    oc_reference_bake._write_texture_png(str(path), texture)
    decoded = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)

    assert np.array_equal(decoded, texture)
