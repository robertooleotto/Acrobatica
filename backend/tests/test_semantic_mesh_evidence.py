import unittest

import numpy as np

from scripts.build_semantic_mesh_evidence import (
    adaptive_keyframes,
    finalize_labels,
    semantic_class,
)


class FakeCamera:
    def __init__(self, key, center):
        self.key = key
        self.center = np.asarray(center, dtype=float)
        self.rotation = np.eye(3)
        self.intrinsics = (100.0, 100.0, 50.0, 50.0)
        self.width = 100
        self.height = 100


class SemanticMeshEvidenceTests(unittest.TestCase):
    def test_prompt_labels_map_to_geometric_roles(self):
        self.assertEqual(semantic_class("French window"), "opening")
        self.assertEqual(semantic_class("balcony railing"), "attachment")
        self.assertEqual(semantic_class("exterior wall"), "wall")

    def test_ai_opening_overrides_wall_prior(self):
        votes = np.zeros((2, 5), np.float32)
        votes[0, 4] = 0.8
        supports = np.zeros((2, 5), np.uint8)
        supports[0, 4] = 2
        observations = np.asarray([2, 2], np.uint16)
        prior_labels = np.asarray([1, 1], np.uint8)
        prior_confidence = np.asarray([0.72, 0.72], np.float32)
        labels, confidence, sources = finalize_labels(
            votes, supports, observations, prior_labels, prior_confidence,
        )
        self.assertEqual(labels.tolist(), [4, 1])
        self.assertGreater(confidence[0], 0.3)
        self.assertEqual(sources.tolist(), [3, 1])


if __name__ == "__main__":
    unittest.main()
