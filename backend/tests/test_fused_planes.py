import json
import math

import numpy as np
import pytest

from fused_planes.build_cgal_planes import (
    classify_plane,
    convex_hull_indices,
    filter_candidates_by_area,
)
from fused_planes.build_fused_planes import (
    build_planes,
    classify_final_plane_types,
    coalesce_plane_segments,
    robust_facade_samples,
)
from fused_planes.build_slice_stack import slice_batch
from fused_planes.build_slice_stack import estimate_global_angle
from fused_planes.build_perimeter_planes import build_candidates
from fused_planes.analysis_frame import estimate_oc_to_arkit
from fused_planes.run import (
    candidate_is_persistent,
    dominant_angle,
    pick_best_slice,
    to_detected_planes,
)


def test_convex_hull_excludes_interior_points():
    points = [[0, 0], [2, 0], [2, 2], [0, 2], [1, 1]]
    hull = convex_hull_indices(points)
    assert set(hull) == {0, 1, 2, 3}


def test_candidate_area_filter_does_not_depend_on_semantic_type():
    main_normal = np.array([0.0, 0.0, 1.0])
    reveal = {"n": np.array([1.0, 0.0, 0.0]), "area": 0.10}
    facade = {"n": np.array([0.0, 0.0, 1.0]), "area": 0.10}

    assert classify_plane(reveal, main_normal) == "spalla"
    assert classify_plane(facade, main_normal) == "facciata"
    assert filter_candidates_by_area([reveal, facade], 0.05) == [reveal, facade]


def test_candidate_requires_persistence_across_slices():
    assert candidate_is_persistent(12, 60, 8.0, 30.0)
    assert not candidate_is_persistent(5, 60, 8.0, 30.0)
    assert not candidate_is_persistent(20, 60, 1.0, 30.0)


def test_batch_slicer_loads_all_requested_heights_in_one_process(tmp_path, monkeypatch):
    calls = []

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        heights = [float(value) for value in open(command[3]).read().splitlines()]
        with open(command[4], "w") as output:
            json.dump({"slices": [
                {"y": y, "contours": [{"length": y}]} for y in heights
            ]}, output)

    monkeypatch.setattr("fused_planes.build_slice_stack.subprocess.run", fake_run)
    result = slice_batch("slicer", "mesh.obj", [0.15, 0.45], 28.0, 0.2, 0.3)

    assert len(calls) == 1
    assert calls[0][0][2] == "--batch"
    assert result == [
        (0.15, [{"length": 0.15}]),
        (0.45, [{"length": 0.45}]),
    ]


def test_global_perimeter_angle_is_derived_in_the_rotated_mesh_frame():
    angle = math.radians(37.0)
    direction = [math.cos(angle), 0.0, math.sin(angle)]
    perpendicular = [-direction[2], 0.0, direction[0]]
    results = [(0.15, [{"length": 20.0, "regularized": [
        [0.0, 0.15, 0.0],
        [direction[0] * 10.0, 0.15, direction[2] * 10.0],
        [direction[0] * 10.0 + perpendicular[0] * 5.0, 0.15,
         direction[2] * 10.0 + perpendicular[2] * 5.0],
    ]}])]
    assert estimate_global_angle(results) == pytest.approx(37.0, abs=0.01)


def test_perimeter_candidates_require_vertical_persistence():
    slices = []
    for index in range(12):
        points = [[0.0, index * 0.3, 0.0], [8.0, index * 0.3, 0.0]]
        if index == 5:
            points += [[8.0, index * 0.3, 2.0], [9.0, index * 0.3, 2.0]]
        slices.append({
            "index": index,
            "y": index * 0.3,
            "contours": [{"regularized": points}],
        })
    result = build_candidates({"slices": slices}, 0.0)
    assert len(result["planes"]) == 1
    assert result["planes"][0]["slice_count"] == 12


def test_oc_to_arkit_similarity_is_estimated_per_session():
    scale = 2.5
    theta = math.radians(31.0)
    rotation = np.array([
        [math.cos(theta), 0.0, math.sin(theta)],
        [0.0, 1.0, 0.0],
        [-math.sin(theta), 0.0, math.cos(theta)],
    ])
    translation = np.array([4.0, -2.0, 7.0])
    source = np.array([[0.0, 0.0, 0.0], [1.0, 0.2, 0.0],
                       [0.0, 1.0, 1.0], [2.0, 0.0, 1.0]])
    target = scale * (rotation @ source.T).T + translation
    oc_poses = {
        str(index): {"translation": point.tolist()}
        for index, point in enumerate(source)
    }
    photos = []
    for index, center in enumerate(target):
        transform = np.eye(4)
        transform[:3, 3] = center
        photos.append({
            "order_index": index,
            "metadata": {"camera_transform": transform.flatten(order="F").tolist()},
        })

    document = estimate_oc_to_arkit(oc_poses, photos)

    assert document["scale"] == pytest.approx(scale)
    assert np.asarray(document["R"]) == pytest.approx(rotation)
    assert np.asarray(document["t"]) == pytest.approx(translation)
    assert document["max_error_m"] < 1e-10


def test_final_types_follow_direction_families_not_candidate_labels():
    planes = [
        {"id": 0, "nome": "candidate", "tipo": "spalla",
         "normale": [0.0, 0.0, 1.0], "w": 10.0},
        {"id": 1, "nome": "candidate", "tipo": "facciata",
         "normale": [1.0, 0.0, 0.0], "w": 2.0},
        {"id": 2, "nome": "candidate", "tipo": "spalla",
         "normale": [0.0, 0.0, -1.0], "w": 10.0},
    ]

    classified = classify_final_plane_types(planes)

    assert [plane["tipo"] for plane in classified] == [
        "facciata", "spalla", "facciata"]


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


def test_detected_planes_are_returned_from_analysis_to_original_oc_frame():
    theta = math.radians(90.0)
    rotation = np.array([
        [math.cos(theta), 0.0, math.sin(theta)],
        [0.0, 1.0, 0.0],
        [-math.sin(theta), 0.0, math.cos(theta)],
    ])
    scale = 2.0
    translation = np.array([10.0, 3.0, -5.0])
    oc_corners = np.array([
        [0.0, 0.0, 0.0], [2.0, 0.0, 0.0],
        [2.0, 4.0, 0.0], [0.0, 4.0, 0.0],
    ])
    analysis_corners = scale * (rotation @ oc_corners.T).T + translation
    analysis_normal = rotation @ np.array([0.0, 0.0, 1.0])
    fused = {"planes": [{
        "nome": "Facciata", "tipo": "facciata",
        "punto": analysis_corners.mean(axis=0).tolist(),
        "normale": analysis_normal.tolist(),
        "corners": analysis_corners.tolist(),
        "area_m2": 8.0, "w": 2.0, "h": 4.0,
    }]}

    plane = to_detected_planes(
        fused, analysis_similarity=(scale, rotation, translation))["planes"][0]

    assert np.asarray(plane["corners"]) == pytest.approx(oc_corners)
    assert plane["normale"] == pytest.approx([0.0, 0.0, 1.0])
