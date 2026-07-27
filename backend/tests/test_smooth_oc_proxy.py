import importlib.util
from pathlib import Path

import numpy as np


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "smooth_oc_proxy.py"
SPEC = importlib.util.spec_from_file_location("smooth_oc_proxy", MODULE_PATH)
smooth_oc_proxy = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(smooth_oc_proxy)


def test_normal_smoothing_reduces_bump_and_keeps_open_boundary():
    vertices = np.array(
        [
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [2.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [1.0, 1.0, 0.08],
            [2.0, 1.0, 0.0],
            [0.0, 2.0, 0.0],
            [1.0, 2.0, 0.0],
            [2.0, 2.0, 0.0],
        ],
        dtype=np.float64,
    )
    faces = np.array(
        [
            [0, 1, 4], [0, 4, 3],
            [1, 2, 5], [1, 5, 4],
            [3, 4, 7], [3, 7, 6],
            [4, 5, 8], [4, 8, 7],
        ],
        dtype=np.int32,
    )

    result, _ = smooth_oc_proxy.smooth_proxy(
        vertices,
        faces,
        iterations=3,
        strength=0.6,
        feature_angle_deg=45.0,
        max_step_m=0.03,
    )

    boundary = np.array([0, 1, 2, 3, 5, 6, 7, 8])
    np.testing.assert_allclose(result[boundary], vertices[boundary])
    assert 0.0 < result[4, 2] < vertices[4, 2]
