"""Test del riconoscimento e dell'estrusione automatica dei balconi."""
import numpy as np
import pytest

from app.services.facade_geometry import detect_and_extrude_balconies


PLANE = {
    "c": [5.0, 3.0, 0.0],
    "n": [0.0, 0.0, 1.0],
    "up": [0.0, 1.0, 0.0],
    "right": [1.0, 0.0, 0.0],
    "bounds": [-5.0, 5.0, -3.0, 3.0],
}


def _surface(u_range, v_range, depth, count, seed):
    rng = np.random.default_rng(seed)
    return np.column_stack([
        5.0 + rng.uniform(*u_range, count),
        3.0 + rng.uniform(*v_range, count),
        rng.normal(depth, 0.015, count),
    ])


def test_detects_two_balconies_and_builds_prisms():
    wall = _surface((-5, 5), (-3, 3), 0.0, 5000, 1)
    first = _surface((-3.5, -1.5), (0.5, 1.7), 0.65, 1000, 2)
    second = _surface((1.0, 3.5), (-1.5, -0.3), 0.90, 1200, 3)

    result = detect_and_extrude_balconies(
        np.vstack([wall, first, second]), PLANE, ppm=100.0)

    assert result["count"] == 2
    depths = sorted(b["depth_m"] for b in result["balconies"])
    assert depths == pytest.approx([0.65, 0.90], abs=0.05)
    assert all(b["confidence"] == "alta" for b in result["balconies"])
    assert all(b["needs_review"] for b in result["balconies"])
    assert len(result["model_json"]["prisms"]) == 2
    assert all(p["tipo"] == "balcone" for p in result["model_json"]["prisms"])


def test_wall_and_small_protrusion_do_not_create_balconies():
    wall = _surface((-5, 5), (-3, 3), 0.0, 5000, 4)
    noise = _surface((0.0, 0.2), (0.0, 0.2), 0.5, 80, 5)
    result = detect_and_extrude_balconies(
        np.vstack([wall, noise]), PLANE, ppm=100.0)
    assert result["count"] == 0
    assert result["model_json"]["n_faces"] == 1  # solo piano base


@pytest.mark.parametrize("kwargs", [
    {"ppm": 0},
    {"ppm": 100, "min_depth_m": 0},
    {"ppm": 100, "cell_size_m": 0},
    {"ppm": 100, "min_points_per_cell": 0},
    {"ppm": 100, "min_area_m2": 0},
    {"ppm": 100, "max_balconies": 0},
])
def test_invalid_parameters(kwargs):
    with pytest.raises(ValueError):
        detect_and_extrude_balconies(np.empty((0, 3)), PLANE, **kwargs)
