import json
import math

import numpy as np
import pytest

from fused_planes.build_cgal_planes import (
    attach_support_bounds,
    classify_plane,
    convex_hull_indices,
    estimate_mesh_resolution,
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
from fused_planes.build_perimeter_planes import build_candidates, slice_observations
from fused_planes.simplify_stack import corner_angle_degrees, simplify_contour
from fused_planes.analysis_frame import estimate_oc_to_arkit
from fused_planes.run import (
    candidate_is_persistent,
    dominant_angle,
    pick_best_slice,
    to_detected_planes,
)
from fused_planes.reconstruct_open_surface import (
    discover_gap_fits,
    reconstruct,
    regularize_envelope_heights,
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


def test_region_growing_distance_scales_with_mesh_geometry(tmp_path):
    def write_triangle(path, scale):
        path.write_text(
            f"v 0 0 0\nv {scale} 0 0\nv 0 {scale} 0\nf 1 2 3\n")

    small = tmp_path / "small.obj"
    large = tmp_path / "large.obj"
    write_triangle(small, 1.0)
    write_triangle(large, 7.0)
    assert estimate_mesh_resolution(large) == pytest.approx(
        estimate_mesh_resolution(small) * 7.0)


def test_mesh_region_support_bounds_are_computed_without_convex_hulls():
    planes = [{
        "n": np.asarray([0.0, 0.0, 1.0]),
        "mem": {2},
    }]
    faces = np.asarray([
        (2, -3.0, 1.0, 4.0),
        (2, 5.0, 9.0, 4.0),
        (7, 100.0, 100.0, 100.0),
    ], dtype=[("region", int), ("cx", float), ("cy", float), ("cz", float)])
    attach_support_bounds(planes, faces)
    assert planes[0]["support_bounds"] == pytest.approx({
        "y_min": 1.0,
        "y_max": 9.0,
        "t_min": -3.0,
        "t_max": 5.0,
    })


def test_candidate_requires_persistence_across_slices():
    assert candidate_is_persistent(12, 60, 8.0, 30.0)
    assert not candidate_is_persistent(5, 60, 8.0, 30.0)
    assert not candidate_is_persistent(20, 60, 1.0, 30.0)


def test_persistent_contour_gap_creates_connector_plane():
    by_slice = []
    connector_observations = []
    for slice_id in range(4):
        y = slice_id * 0.3
        connector = {
            "slice": slice_id, "contour": 0, "order": 1, "track": 30,
            "y": y, "a": [0.0, y, 1.0], "b": [4.0, y, 1.0],
            "length": 4.0,
        }
        connector_observations.append(connector)
        by_slice.append([
            {
                "slice": slice_id, "contour": 0, "order": 0, "track": 10,
                "y": y, "a": [0.0, y, 0.0], "b": [0.0, y, 1.0],
                "length": 1.0,
            },
            connector,
            {
                "slice": slice_id, "contour": 0, "order": 2, "track": 20,
                "y": y, "a": [4.0, y, 1.0], "b": [4.0, y, 0.0],
                "length": 1.0,
            },
        ])
    base_fits = [
        {
            "id": 0, "center": np.array([0.0, 0.45, 0.5]),
            "normal": np.array([1.0, 0.0, 0.0]), "source_tracks": {10},
            "mesh_support_bounds": {"y_min": 0.0, "y_max": 0.9},
        },
        {
            "id": 1, "center": np.array([4.0, 0.45, 0.5]),
            "normal": np.array([1.0, 0.0, 0.0]), "source_tracks": {20},
            "mesh_support_bounds": {"y_min": 0.0, "y_max": 0.9},
        },
    ]
    unassigned = [{
        "observations": connector_observations,
        "center": np.array([2.0, 0.45, 1.0]),
        "normal": np.array([0.0, 0.0, 1.0]),
        "source_tracks": {30},
    }]
    thresholds = {"angle_rad": math.radians(10), "step": 0.3,
                  "line_distance": 0.1}

    supplemental = discover_gap_fits(
        by_slice, base_fits, unassigned, thresholds)

    assert len(supplemental) == 1
    assert supplemental[0]["gap_neighbors"] == (0, 1)
    assert supplemental[0]["mesh_support_bounds"] == {
        "y_min": 0.0, "y_max": 0.9,
    }


def test_envelope_height_policy_aligns_persistent_surfaces():
    extents = [
        {"y_min": 0.0, "y_max": 10.0},
        {"y_min": 0.6, "y_max": 9.4},
        {"y_min": 3.0, "y_max": 7.0},
        {"y_min": 4.0, "y_max": 6.0},
    ]

    policy = regularize_envelope_heights(
        extents, {(0, 1), (0, 2)}, fit_weights=[100.0, 40.0, 10.0, 5.0])

    assert extents[0]["y_min"] == pytest.approx(0.0)
    assert extents[0]["y_max"] == pytest.approx(10.0)
    assert extents[1]["y_min"] == pytest.approx(0.0)
    assert extents[1]["y_max"] == pytest.approx(10.0)
    assert policy[0]["height_aligned"]
    assert policy[1]["height_aligned"]


def test_envelope_height_policy_keeps_connected_returns_only():
    extents = [
        {"y_min": 0.0, "y_max": 10.0},
        {"y_min": 3.0, "y_max": 7.0},
        {"y_min": 4.0, "y_max": 6.0},
    ]

    policy = regularize_envelope_heights(
        extents, {(0, 1)}, fit_weights=[100.0, 10.0, 5.0])

    assert policy[1]["retain"]
    assert not policy[1]["height_aligned"]
    assert not policy[2]["retain"]
    assert policy[0]["envelope_component"] == policy[1]["envelope_component"]
    assert policy[2]["envelope_component"] != policy[0]["envelope_component"]


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


def test_slice_simplification_preserves_coherent_oblique_edges():
    points = [
        [0.0, 2.0, 0.0],
        [1.0, 2.0, 0.40],
        [2.0, 2.0, 0.82],
        [3.0, 2.0, 1.20],
        [4.0, 2.0, 1.62],
    ]

    simplified = simplify_contour(
        points, False, epsilon=0.08, min_points_closed=6,
        angle_deg=None, line_tolerance=0.0, min_edge=0.0)

    assert len(simplified) == 2
    assert simplified[0] == pytest.approx(points[0])
    assert simplified[-1] == pytest.approx(points[-1])


def test_slice_simplification_snaps_angles_within_ten_degrees_to_right_angle():
    direction = math.radians(180.0 - 99.0)
    points = [
        [0.0, 2.0, 0.0],
        [2.0, 2.0, 0.0],
        [2.0 + 1.5 * math.cos(direction), 2.0, 1.5 * math.sin(direction)],
    ]

    simplified = simplify_contour(
        points, False, epsilon=0.01, min_points_closed=6,
        angle_deg=None, line_tolerance=0.0, min_edge=0.0)

    assert corner_angle_degrees(*simplified) == pytest.approx(90.0, abs=1e-5)


def test_slice_simplification_keeps_angles_outside_ten_degree_tolerance():
    direction = math.radians(180.0 - 101.0)
    points = [
        [0.0, 2.0, 0.0],
        [2.0, 2.0, 0.0],
        [2.0 + 1.5 * math.cos(direction), 2.0, 1.5 * math.sin(direction)],
    ]

    simplified = simplify_contour(
        points, False, epsilon=0.01, min_points_closed=6,
        angle_deg=None, line_tolerance=0.0, min_edge=0.0)

    assert corner_angle_degrees(*simplified) == pytest.approx(101.0)


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


def test_oblique_slice_edges_are_not_projected_onto_building_axes():
    diagonal = [[0.0, 1.0, 0.0], [4.0, 1.0, 2.0]]
    slice_data = {
        "index": 0,
        "y": 1.0,
        "contours": [{"regularized": diagonal}],
    }

    assert slice_observations(slice_data, angle_deg=0.0) == []


def _synthetic_slice_stack(angle_deg=0.0, scale=1.0):
    angle = math.radians(angle_deg)
    rotation = np.array([
        [math.cos(angle), -math.sin(angle)],
        [math.sin(angle), math.cos(angle)],
    ])
    # Three connected faces, including a deliberately non-Manhattan 73 degree corner.
    base = np.asarray([[0.0, 0.0], [8.0, 0.0], [9.46, 4.38], [13.0, 4.38]]) * scale
    slices = []
    for index in range(12):
        y = index * 0.3 * scale
        xz_points = (rotation @ base.T).T
        points = [[float(point[0]), y, float(point[1])] for point in xz_points]
        slices.append({
            "index": index,
            "y": y,
            "contours": [{"raw": points, "regularized": points}],
        })
    return {"step_m": 0.3 * scale, "slices": slices}


@pytest.mark.parametrize("angle_deg", [0.0, 31.0, 79.0])
def test_multi_slice_reconstruction_is_rotation_invariant_and_keeps_oblique_faces(angle_deg):
    result = reconstruct(_synthetic_slice_stack(angle_deg=angle_deg))
    assert len(result["planes"]) == 3
    assert sorted(plane["w"] for plane in result["planes"]) == pytest.approx(
        sorted([8.0, math.hypot(1.46, 4.38), 3.54]), abs=0.05)
    assert all(plane["fit_mode"] == "multi_slice_free_orientation"
               for plane in result["planes"])


def test_multi_slice_reconstruction_scales_with_metric_input():
    normal = reconstruct(_synthetic_slice_stack(scale=1.0))["planes"]
    enlarged = reconstruct(_synthetic_slice_stack(scale=4.0))["planes"]
    assert sorted(plane["w"] for plane in enlarged) == pytest.approx(
        [value * 4.0 for value in sorted(plane["w"] for plane in normal)], rel=0.02)
    assert sorted(plane["h"] for plane in enlarged) == pytest.approx(
        [value * 4.0 for value in sorted(plane["h"] for plane in normal)], rel=0.02)


def test_multi_slice_reconstruction_uses_shared_corners_for_connected_faces():
    planes = reconstruct(_synthetic_slice_stack(angle_deg=23.0))["planes"]
    shared_pairs = 0
    for index, first in enumerate(planes):
        for second in planes[index + 1:]:
            distance = min(
                math.dist(a, b)
                for a in first["corners"] for b in second["corners"]
            )
            shared_pairs += distance < 1e-6
    assert shared_pairs == 2


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
