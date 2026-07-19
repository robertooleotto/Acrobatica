from copy import deepcopy

import numpy as np
import pytest

from app.services import opening_detection_service as service


def _projection():
    return {
        "total_area_m2": 24.0,
        "files": [{"name": "plane_1_main.png", "path": "remote/plane.png", "size": 10}],
        "planes": [{
            "index": 1,
            "file": "plane_1_main.png",
            "width_m": 6.0,
            "height_m": 4.0,
            "tex_w": 600,
            "tex_h": 400,
            "area_m2": 24.0,
        }],
    }


def _opening(identifier="one", excluded=True):
    return {
        "id": identifier,
        "plane_index": 1,
        "type": "window",
        "polygon_uv": [[0.1, 0.25], [0.3, 0.25], [0.3, 0.75], [0.1, 0.75]],
        "confidence": 0.9,
        "area_m2": 999.0,
        "excluded": excluded,
        "source": "grounded_sam2",
    }


def test_mask_polygon_converts_image_y_to_bottom_left_uv():
    mask = np.zeros((100, 200), np.uint8)
    mask[20:80, 40:120] = 1

    polygon = service._mask_polygon(mask, (100, 200))

    us = [point[0] for point in polygon]
    vs = [point[1] for point in polygon]
    assert min(us) == pytest.approx(40 / 199, abs=0.01)
    assert max(us) == pytest.approx(119 / 199, abs=0.01)
    assert min(vs) == pytest.approx(1 - 79 / 99, abs=0.01)
    assert max(vs) == pytest.approx(1 - 20 / 99, abs=0.01)


def test_totals_recompute_metric_area_and_union_overlaps():
    first = _opening("one")
    duplicate = _opening("two")

    result = service._totals(_projection(), [first, duplicate])

    assert result["openings"][0]["area_m2"] == pytest.approx(2.4, abs=0.01)
    assert result["excluded_area_m2"] == pytest.approx(2.4, abs=0.05)
    assert result["net_area_m2"] == pytest.approx(21.6, abs=0.05)


def test_review_can_only_change_excluded_flag(monkeypatch):
    session = {
        "id": "session-1",
        "result": {
            "projection": _projection(),
            "metric_openings": {
                **service._totals(_projection(), [_opening()]),
                "detector_model": "detector",
                "segmenter_model": "segmenter",
            },
        },
    }

    def get_session(_):
        return deepcopy(session)

    def update_session(_, fields):
        session.update(deepcopy(fields))
        return deepcopy(session)

    monkeypatch.setattr(service.session_store, "get_session", get_session)
    monkeypatch.setattr(service.session_store, "update_session", update_session)
    tampered = _opening(excluded=False)
    tampered["polygon_uv"] = [[0, 0], [1, 0], [1, 1], [0, 1]]
    tampered["area_m2"] = 24

    result = service.save_review("session-1", [tampered])

    saved = result["openings"][0]
    assert saved["excluded"] is False
    assert saved["polygon_uv"] == _opening()["polygon_uv"]
    assert saved["area_m2"] == pytest.approx(2.4)
    assert result["net_area_m2"] == pytest.approx(24.0)


def test_deduplicate_keeps_best_overlapping_box():
    proposals = [
        {"box": [0, 0, 100, 100], "score": 0.7, "label": "window"},
        {"box": [2, 2, 98, 98], "score": 0.9, "label": "window"},
        {"box": [120, 0, 180, 100], "score": 0.8, "label": "door"},
    ]

    result = service._deduplicate(proposals)

    assert [item["score"] for item in result] == [0.9, 0.8]


def test_tiles_cover_the_full_4k_image_without_gaps():
    bounds = service._tile_bounds((4096, 3520), tile_size=2048, overlap=384)
    coverage = np.zeros((3520, 4096), np.uint8)
    for x0, y0, x1, y1 in bounds:
        coverage[y0:y1, x0:x1] = 1

    assert coverage.all()
    assert bounds[0][:2] == (0, 0)
    assert bounds[-1][2:] == (4096, 3520)


def test_tiled_segmentation_returns_polygons_in_original_coordinates():
    image = service.Image.new("RGB", (3000, 1800))
    proposals = [{
        "box": [1700, 500, 1900, 800],
        "score": 0.9,
        "label": "window",
        "_tile": (1200, 200, 2600, 1600),
    }]

    def segmenter(tile, boxes, runtime):
        mask = np.zeros((tile.height, tile.width), np.uint8)
        x0, y0, x1, y1 = (int(value) for value in boxes[0])
        mask[y0:y1, x0:x1] = 1
        return [mask]

    polygons = service._segment_polygons_tiled(
        image, proposals, runtime=None, segmenter=segmenter)

    us = [point[0] for point in polygons[0]]
    vs = [point[1] for point in polygons[0]]
    assert min(us) == pytest.approx(1700 / 2999, abs=0.002)
    assert max(us) == pytest.approx(1899 / 2999, abs=0.002)
    assert min(vs) == pytest.approx(1 - 799 / 1799, abs=0.002)
    assert max(vs) == pytest.approx(1 - 500 / 1799, abs=0.002)


def test_tiled_segmentation_rejects_a_mask_that_is_the_whole_tile():
    image = service.Image.new("RGB", (4096, 3520))
    proposals = [{
        "box": [0, 0, 2048, 2048],
        "score": 0.5,
        "label": "shop window",
        "_tile": (0, 0, 2048, 2048),
    }]

    def segmenter(tile, boxes, runtime):
        return [np.ones((tile.height, tile.width), np.uint8)]

    polygons = service._segment_polygons_tiled(
        image, proposals, runtime=None, segmenter=segmenter)

    assert polygons == [[]]


def test_opening_prompts_cover_occluded_balcony_and_storefront_types():
    prompts = {label.lower() for label in service._PROMPT_LABELS[0]}
    assert {"window", "door", "balcony door", "french window", "storefront"} <= prompts
