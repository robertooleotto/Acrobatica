import json
import math

import pytest

from fused_planes.build_cgal_planes import convex_hull_indices
from fused_planes.build_fused_planes import (
    build_planes,
    coalesce_plane_segments,
    robust_facade_samples,
)
from fused_planes.run import dominant_angle, pick_best_slice, to_detected_planes


def test_convex_hull_excludes_interior_points():
    points = [[0, 0], [2, 0], [2, 2], [0, 2], [1, 1]]
    hull = convex_hull_indices(points)
    assert set(hull) == {0, 1, 2, 3}


def test_pick_best_slice_uses_stable_lower_middle_ring(tmp_path):
    slices = []
    for i in range(11):
        slices.append({"y": float(i), "main_length": 20.0, "main_reg_pts": 8})
    slices[1]["main_length"] = 100.0  # Ground-level protrusions must not win.
    path = tmp_path / "stack.json"
    path.write_text(json.dumps({"slices": slices}))
    assert pick_best_slice(path) in {3, 4}


def test_dominant_angle_follows_largest_vertical_plane(tmp_path):
    path = tmp_path / "planes.json"
    path.write_text(json.dumps({"planes": [
        {"area_m2": 5.0, "normale": [1.0, 0.0, 0.0]},
        {"area_m2": 20.0, "normale": [-0.5, 0.05, math.sqrt(0.75)]},
        {"area_m2": 50.0, "normale": [0.0, 1.0, 0.0]},
    ]}))
    assert dominant_angle(path) == pytest.approx(30.0, abs=0.1)


def test_perimeter_fit_rejects_balcony_offset_cluster():
    facade = [(float(y), 0.05, 2.0) for y in range(10)]
    balcony = [(4.0, 1.25, 2.0), (5.0, 1.30, 2.0)]
    kept = robust_facade_samples(facade + balcony)
    assert len(kept) == len(facade)
    assert max(abs(offset) for _, offset, _ in kept) < 0.2


def test_short_protrusion_between_same_plane_is_bridged():
    segments = [
        {"plane_id": 3, "joined_a": [0, 1, 0], "joined_b": [2, 1, 0], "length": 2},
        {"plane_id": None, "joined_a": [2, 1, 0], "joined_b": [3, 1, 1], "length": 1.4},
        {"plane_id": 3, "joined_a": [3, 1, 1], "joined_b": [5, 1, 0], "length": 2},
    ]
    merged = coalesce_plane_segments(segments)
    assert len(merged) == 1
    assert merged[0]["joined_a"] == [0, 1, 0]
    assert merged[0]["joined_b"] == [5, 1, 0]
    assert merged[0]["bridged_unassigned_m"] == pytest.approx(1.4)


def test_shared_extrusion_makes_facade_and_reveal_rectangular():
    fusion = {
        "planes": [],
        "segments": [
            {
                "index": 0, "plane_id": 1,
                "joined_a": [0.0, 5.0, 0.0],
                "joined_b": [4.0, 5.0, 0.0],
                "length": 4.0, "distance": 0.0, "angle_diff": 0.0,
            },
            {
                "index": 1, "plane_id": 2,
                "joined_a": [4.0, 5.0, 0.0],
                "joined_b": [4.0, 5.0, 2.0],
                "length": 2.0, "distance": 0.0, "angle_diff": 0.0,
            },
        ],
    }
    sources = {
        1: {
            "id": 1, "name": "Facciata 1", "type": "facciata",
            "point": [0.0, 0.0, 0.0], "normal": [0.0, -0.04, 1.0],
            "fit_weight": 100.0,
        },
        # Rumore di inclinazione indipendente sulla spalletta: non deve piu'
        # produrre due intersezioni diverse alla base e alla sommita'.
        2: {
            "id": 2, "name": "Spalletta 1", "type": "spalla",
            "point": [4.0, 0.0, 0.0], "normal": [1.0, 0.03, 0.0],
            "fit_weight": 20.0,
        },
    }

    planes = build_planes(fusion, sources, ymin=0.0, ymax=10.0)
    assert len(planes) == 2

    side_vectors = []
    for plane in planes:
        c0, c1, c2, c3 = plane["corners"]
        assert math.dist(c0, c1) == pytest.approx(math.dist(c3, c2), abs=1e-8)
        assert math.dist(c0, c3) == pytest.approx(math.dist(c1, c2), abs=1e-8)
        bottom = [c1[i] - c0[i] for i in range(3)]
        side = [c3[i] - c0[i] for i in range(3)]
        assert sum(bottom[i] * side[i] for i in range(3)) == pytest.approx(0.0, abs=1e-8)
        side_vectors.append(side)

    assert side_vectors[0] == pytest.approx(side_vectors[1], abs=1e-8)
    assert planes[0]["corners"][1] == pytest.approx(planes[1]["corners"][0], abs=1e-8)
    assert planes[0]["corners"][2] == pytest.approx(planes[1]["corners"][3], abs=1e-8)


def test_nearly_parallel_neighbors_do_not_create_remote_edges():
    fusion = {
        "planes": [],
        "segments": [
            {
                "index": 0, "plane_id": 1,
                "joined_a": [0.0, 2.0, 0.0],
                "joined_b": [4.0, 2.0, 0.0],
                "length": 4.0, "distance": 0.0, "angle_diff": 0.0,
            },
            {
                "index": 1, "plane_id": 2,
                "joined_a": [4.0, 2.0, 0.0],
                "joined_b": [8.0, 2.0, 0.05],
                "length": 4.0, "distance": 0.0, "angle_diff": 0.0,
            },
        ],
    }
    sources = {
        1: {
            "id": 1, "name": "Facciata 1", "type": "facciata",
            "point": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0],
            "fit_weight": 100.0,
        },
        2: {
            "id": 2, "name": "Facciata 2", "type": "facciata",
            "point": [0.0, 0.0, 1.0], "normal": [0.02, 0.0, 0.9998],
            "fit_weight": 100.0,
        },
    }

    planes = build_planes(fusion, sources, ymin=0.0, ymax=10.0)

    assert len(planes) == 2
    assert max(abs(value) for plane in planes for corner in plane["corners"]
               for value in corner) < 20.0
    assert max(plane["w"] for plane in planes) < 10.0


def test_detected_planes_return_mesh_frame_and_metric_measurements():
    fused = {"planes": [{
        "nome": "Facciata 1", "tipo": "facciata", "punto": [2.0, 4.0, 6.0],
        "normale": [0.0, 0.0, 1.0],
        "corners": [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0],
                    [2.0, 4.0, 0.0], [0.0, 4.0, 0.0]],
        "area_m2": 8.0, "w": 2.0, "h": 4.0,
    }]}
    out = to_detected_planes(fused, oc_scale=2.0)
    plane = out["planes"][0]
    assert plane["punto"] == [1.0, 2.0, 3.0]
    assert plane["corners"][1] == [1.0, 0.0, 0.0]
    assert plane["area_m2"] == 8.0
    assert plane["w"] == 2.0
