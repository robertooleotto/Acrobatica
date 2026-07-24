import math
import unittest

import numpy as np

from scripts.detect_planes_multiscale import (
    assign_plane_families,
    associate_regions,
    build_candidates_v2,
    build_contour_envelope,
    build_family_reassignment_proposals,
    build_family_envelope_faces,
    build_horizontal_section_evidence,
    build_topology_proposals,
    classify_envelope_roles,
    classify_candidate_support,
    robust_plane,
    section_continuity,
    voxelize,
)
from scripts.detect_planes_multiscale_online import envelope_face_to_plane


def candidate(index, center, normal, support=600, rms=0.005):
    center = np.asarray(center, dtype=float)
    normal = np.asarray(normal, dtype=float)
    normal /= np.linalg.norm(normal)
    up = np.asarray([0.0, 1.0, 0.0])
    horizontal = np.cross(up, normal)
    horizontal /= np.linalg.norm(horizontal)
    corners = [
        center - horizontal - up,
        center + horizontal - up,
        center + horizontal + up,
        center - horizontal + up,
    ]
    return {
        "id": index,
        "kind": "vertical",
        "confidence": "high",
        "support_points": support,
        "center": center.tolist(),
        "normal": normal.tolist(),
        "corners": [corner.tolist() for corner in corners],
        "rms": rms,
    }


class MultiscalePlanesTests(unittest.TestCase):
    def test_online_adapter_preserves_offline_corners_and_metric_dimensions(self):
        face = {
            "family_id": 7,
            "envelope_role": "return",
            "normal": [1.0, 0.0, 0.0],
            "corners": [
                [2.0, 1.0, 3.0], [2.0, 1.0, 5.0],
                [2.0, 4.0, 5.0], [2.0, 4.0, 3.0],
            ],
            "height_aligned": True,
            "snapped_junction_ids": [2],
        }
        plane = envelope_face_to_plane(face, 1, scale=2.0)
        self.assertEqual(plane["corners"], face["corners"])
        self.assertEqual(plane["tipo"], "spalla")
        self.assertAlmostEqual(plane["w"], 4.0)
        self.assertAlmostEqual(plane["h"], 6.0)
        self.assertAlmostEqual(plane["area_m2"], 24.0)
        self.assertEqual(plane["family_id"], 7)

    def test_voxelization_is_independent_from_input_order(self):
        points = np.asarray([
            [0.00, 0.00, 0.00],
            [0.01, 0.00, 0.00],
            [1.00, 0.00, 0.00],
            [1.01, 0.00, 0.00],
        ])
        normals = np.tile([0.0, 0.0, 1.0], (4, 1))
        first_points, first_normals = voxelize(points, normals, 0.1)
        order = np.asarray([2, 0, 3, 1])
        second_points, second_normals = voxelize(points[order], normals[order], 0.1)
        np.testing.assert_allclose(first_points, second_points)
        np.testing.assert_allclose(first_normals, second_normals)

    def test_robust_fit_rejects_distant_balcony_samples(self):
        rng = np.random.default_rng(7)
        xy = rng.uniform(-2.0, 2.0, size=(800, 2))
        base = np.column_stack((xy[:, 0], xy[:, 1], 0.2 * xy[:, 0] + 1.0))
        base[:, 2] += rng.normal(0.0, 0.003, size=len(base))
        outliers = rng.uniform(-1.0, 1.0, size=(40, 3))
        outliers[:, 2] += 2.0
        points = np.vstack((base, outliers))
        expected = np.asarray([-0.2, 0.0, 1.0])
        expected /= np.linalg.norm(expected)
        _, normal, _ = robust_plane(points, expected)
        self.assertGreater(abs(float(normal @ expected)), math.cos(math.radians(1.0)))

    def test_cross_scale_overlap_associates_same_region(self):
        fine = [{
            "scale": "fine", "region": 0, "npoints": 4,
            "normal": np.asarray([0.0, 0.0, 1.0]), "d": -1.0,
            "center": np.asarray([0.0, 0.0, 1.0]), "rms": 0.01,
            "max_distance": 0.02,
        }]
        medium = [{
            "scale": "medium", "region": 3, "npoints": 5,
            "normal": np.asarray([0.0, 0.0, 1.0]), "d": -1.005,
            "center": np.asarray([0.0, 0.0, 1.005]), "rms": 0.01,
            "max_distance": 0.03,
        }]
        labels = [np.asarray([0, 0, 0, 0, -1]), np.asarray([3, 3, 3, 3, 3])]
        groups = associate_regions([fine, medium], labels)
        self.assertEqual(len(groups), 1)
        self.assertEqual({node["scale"] for node in groups[0]}, {"fine", "medium"})

    def test_plane_families_do_not_merge_different_depths(self):
        points = np.asarray([
            [-4.0, -2.0, 0.0], [4.0, -2.0, 0.0],
            [-4.0, 2.0, 0.0], [4.0, 2.0, 0.0],
        ])
        candidates = [
            candidate(0, [-1.0, 0.0, 1.000], [0.0, 0.0, 1.0]),
            candidate(1, [1.0, 0.0, 1.015], [0.0, 0.0, 1.0]),
            candidate(2, [0.0, 0.0, 1.300], [0.00, 0.0, 1.0]),
        ]
        families = assign_plane_families(candidates, points, voxel=0.01)
        self.assertEqual(len(families), 2)
        self.assertEqual(candidates[0]["family_id"], candidates[1]["family_id"])
        self.assertNotEqual(candidates[0]["family_id"], candidates[2]["family_id"])

    def test_diagnostic_keeps_structural_only_protrusions_out_of_core(self):
        rng = np.random.default_rng(12)
        core = np.column_stack((
            rng.uniform(-1.0, 1.0, 300),
            rng.uniform(-1.0, 1.0, 300),
            rng.normal(0.0, 0.002, 300),
        ))
        protrusion = np.column_stack((
            rng.uniform(-0.5, 0.5, 60),
            rng.uniform(-0.2, 0.2, 60),
            rng.normal(0.045, 0.002, 60),
        ))
        points = np.vstack((core, protrusion))
        normals = np.tile([0.0, 0.0, 1.0], (len(points), 1))
        indices = np.arange(len(points))
        fine = np.r_[np.ones(len(core), dtype=bool), np.zeros(len(protrusion), dtype=bool)]
        diagnostic = classify_candidate_support(
            points,
            normals,
            indices,
            {"fine": fine, "medium": fine.copy(), "structural": np.ones(len(points), dtype=bool)},
            np.asarray([0.0, 0.0, 0.0]),
            np.asarray([0.0, 0.0, 1.0]),
            voxel=0.01,
        )
        self.assertGreaterEqual(diagnostic["core_count"], 290)
        self.assertEqual(diagnostic["structural_only_count"], len(protrusion))
        self.assertEqual(diagnostic["attachment_count"], len(protrusion))

    def test_topology_proposes_scale_relative_vertical_bridge(self):
        points = np.asarray([
            [x, y, 0.0]
            for y in np.linspace(-0.2, 0.2, 12)
            for x in np.linspace(-0.3, 0.3, 8)
        ])
        normals = np.tile([0.0, 0.0, 1.0], (len(points), 1))
        candidates = [
            candidate(0, [0.0, -1.2, 0.0], [0.0, 0.0, 1.0]),
            candidate(1, [0.0, 1.2, 0.0], [0.0, 0.0, 1.0]),
        ]
        candidates[0]["corners"] = [[-1, -2, 0], [1, -2, 0], [1, -0.2, 0], [-1, -0.2, 0]]
        candidates[1]["corners"] = [[-1, 0.2, 0], [1, 0.2, 0], [1, 2, 0], [-1, 2, 0]]
        candidates[0]["family_id"] = candidates[1]["family_id"] = 0
        family = {
            "id": 0,
            "normal": [0.0, 0.0, 1.0],
            "d": 0.0,
            "members": [0, 1],
            "vertical_extent": 4.0,
            "horizontal_extent": 2.0,
        }
        proposals = build_topology_proposals(
            candidates, [family], points, normals, voxel=0.02
        )
        self.assertEqual(len(proposals), 1)
        self.assertEqual(proposals[0]["axis"], "vertical")
        self.assertEqual(proposals[0]["members"], [0, 1])
        self.assertEqual(proposals[0]["status"], "proposed")

        section_evidence = {
            "step": 0.1,
            "levels": [
                {"y": y, "families": {"0": [[-1.0, 1.0, 2.0]]}}
                for y in (-0.15, 0.0, 0.15)
            ],
        }
        verified = build_topology_proposals(
            candidates, [family], points, normals, voxel=0.02,
            section_evidence=section_evidence,
        )
        self.assertEqual(verified[0]["status"], "accepted")
        self.assertEqual(verified[0]["section_evidence"]["supported_sections"], 3)

    def test_local_clean_core_can_be_reassigned_to_overlapping_family(self):
        candidates = [
            candidate(0, [0.0, 0.0, 0.012], [0.03, 0.0, 1.0], rms=0.02),
            candidate(1, [0.0, 0.0, 0.0], [0.0, 0.0, 1.0], rms=0.004),
        ]
        for index, item in enumerate(candidates):
            item["family_id"] = index
            item["role"] = "detail" if index == 0 else "structural"
            item["diagnostic"] = {
                "core_count": 400,
                "clean_normal": item["normal"],
                "clean_center": item["center"],
                "clean_corners": item["corners"],
                "clean_rms": 0.004,
            }
        families = [
            {"id": 0, "normal": candidates[0]["normal"], "d": -0.012, "rms": 0.02, "members": [0], "role": "detail"},
            {"id": 1, "normal": [0.0, 0.0, 1.0], "d": 0.0, "rms": 0.004, "members": [1], "role": "structural"},
        ]
        proposals = build_family_reassignment_proposals(candidates, families, voxel=0.01)
        proposal = next(item for item in proposals if item["candidate_id"] == 0)
        self.assertEqual(proposal["from_family_id"], 0)
        self.assertEqual(proposal["to_family_id"], 1)

    def test_horizontal_sections_measure_wall_continuity(self):
        vertices = np.asarray([
            [-2.0, -1.0, 0.0], [2.0, -1.0, 0.0],
            [2.0, 1.0, 0.0], [-2.0, 1.0, 0.0],
        ])
        faces = np.asarray([[0, 1, 2], [0, 2, 3]])
        families = [{
            "id": 0, "normal": [0.0, 0.0, 1.0], "d": 0.0,
            "rms": 0.002, "members": [0],
        }]
        evidence = build_horizontal_section_evidence(vertices, faces, families, voxel=0.02)
        continuity = section_continuity(evidence, 0, (-1.5, 1.5), (-0.8, 0.8), voxel=0.02)
        self.assertGreater(continuity["section_count"], 10)
        self.assertGreater(continuity["continuity_ratio"], 0.95)

    def test_v2_applies_only_accepted_reassignment(self):
        item = candidate(0, [0.0, 0.0, 0.02], [0.0, 0.0, 1.0])
        item["family_id"] = 0
        item["role"] = "detail"
        item["diagnostic"] = {
            "clean_normal": [0.0, 0.0, 1.0],
            "clean_center": [0.0, 0.0, 0.02],
            "attachment_points": [3, 4],
        }
        families = [
            {"id": 0, "normal": [0.0, 0.0, 1.0], "d": -0.02, "role": "detail"},
            {"id": 1, "normal": [0.0, 0.0, 1.0], "d": 0.0, "role": "structural"},
        ]
        reassignment = [{
            "id": 0, "candidate_id": 0, "from_family_id": 0,
            "to_family_id": 1, "status": "accepted", "confidence": "high",
            "confidence_score": 0.9,
        }]
        result = build_candidates_v2([item], families, [], reassignment, {"step": 0.1, "levels": []})
        self.assertTrue(result["faces"][0]["reassigned"])
        self.assertEqual(result["faces"][0]["family_id"], 1)
        np.testing.assert_allclose(np.asarray(result["faces"][0]["corners"])[:, 2], 0.0)
        self.assertEqual(result["attachments"][0]["point_indices"], [3, 4])

    def test_persistent_narrow_return_is_promoted_and_snapped_to_shared_edge(self):
        main = candidate(0, [0.0, 0.0, 0.0], [0.0, 0.0, 1.0], support=1200)
        main["corners"] = [
            [-2.0, -2.0, 0.0], [2.0, -2.0, 0.0],
            [2.0, 2.0, 0.0], [-2.0, 2.0, 0.0],
        ]
        side = candidate(1, [-2.0, 0.0, 0.165], [1.0, 0.0, 0.0], support=120)
        side["corners"] = [
            [-2.0, -2.0, 0.30], [-2.0, -2.0, 0.03],
            [-2.0, -0.6, 0.03], [-2.0, -0.6, 0.30],
        ]
        side_upper = candidate(2, [-2.0, 1.3, 0.165], [1.0, 0.0, 0.0], support=100)
        side_upper["corners"] = [
            [-2.0, 0.6, 0.30], [-2.0, 0.6, 0.03],
            [-2.0, 2.0, 0.03], [-2.0, 2.0, 0.30],
        ]
        for index, item in enumerate((main, side, side_upper)):
            item["family_id"] = 0 if index == 0 else 1
            item["role"] = "structural" if index == 0 else "detail"
            item["diagnostic"] = {
                "clean_normal": item["normal"],
                "clean_center": item["center"],
                "clean_corners": item["corners"],
                "attachment_points": [],
            }
        families = [
            {
                "id": 0, "normal": [0.0, 0.0, 1.0], "d": 0.0,
                "members": [0], "role": "structural", "support_points": 1200,
            },
            {
                "id": 1, "normal": [1.0, 0.0, 0.0], "d": 2.0,
                "members": [1, 2], "role": "detail", "support_points": 220,
            },
        ]
        sections = {
            "step": 1.0,
            "levels": [
                {
                    "y": y,
                    "families": {
                        "0": [[-2.0, 2.0, 4.0]],
                        "1": [[-0.30, -0.03, 0.27]],
                    },
                }
                for y in (-1.5, -0.5, 0.0, 0.5, 1.5)
            ],
        }
        junctions = classify_envelope_roles(
            [main, side, side_upper], families, sections, voxel=0.02
        )
        self.assertEqual(families[1]["role"], "structural")
        self.assertEqual(families[1]["envelope_role"], "return")
        self.assertEqual(len(junctions), 1)

        result = build_candidates_v2(
            [main, side, side_upper], families, [], [], sections, junctions
        )
        corrected_side = next(
            face for face in result["faces"]
            if face["family_id"] == 1 and not face.get("family_fill")
        )
        side_corners = np.asarray(corrected_side["corners"])
        self.assertEqual(corrected_side["snapped_junction_ids"], [0])
        self.assertEqual(int(np.isclose(side_corners[:, 2], 0.0).sum()), 2)
        fills = [face for face in result["faces"] if face.get("family_fill")]
        self.assertEqual(len(fills), 1)
        fill_y = np.asarray(fills[0]["corners"])[:, 1]
        self.assertAlmostEqual(float(fill_y.min()), -0.6)
        self.assertAlmostEqual(float(fill_y.max()), 0.6)
        envelope_faces = build_family_envelope_faces(
            [main, side, side_upper], families, junctions, voxel=0.02
        )
        self.assertEqual(len(envelope_faces), 2)
        envelope_side = next(face for face in envelope_faces if face["family_id"] == 1)
        envelope_y = np.asarray(envelope_side["corners"])[:, 1]
        self.assertAlmostEqual(float(envelope_y.min()), -2.0)
        self.assertAlmostEqual(float(envelope_y.max()), 2.0)

    def test_contour_envelope_tracks_narrow_returns_without_width_threshold(self):
        levels = []
        for index in range(20):
            y = index * 0.1
            levels.append({
                "y": y,
                "families": {},
                "contours": [{
                    "length": 4.6,
                    "closed": False,
                    "points": [
                        [-2.0, y, 0.3], [-2.0, y, 0.0],
                        [2.0, y, 0.0], [2.0, y, 0.3],
                    ],
                }],
            })
        result = build_contour_envelope(
            {"step": 0.1, "levels": levels}, voxel=0.02
        )
        self.assertEqual(len(result["faces"]), 3)
        self.assertEqual(len(result["junctions"]), 2)
        narrow = [
            track for track in result["tracks"]
            if track["median_length"] < 0.5
        ]
        self.assertEqual(len(narrow), 2)
        self.assertTrue(all(track["support_sections"] == 20 for track in narrow))


if __name__ == "__main__":
    unittest.main()
