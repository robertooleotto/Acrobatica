import math

import numpy as np
import pytest

from app.services.plane_geometry import regularize_planes_document


def _plane(name, normal, corners):
    return {"nome": name, "tipo": "spalletta" if "Spalletta" in name else "facciata",
            "normale": normal, "punto": np.mean(corners, axis=0).tolist(),
            "corners": corners}


def test_connected_facade_chain_gets_rectangular_shared_extrusion():
    planes = [
        _plane("Facciata 1", [0, 0.04, 1], [
            [0, 0.01, 0], [4, 0.00, 0], [4.10, 10.02, -0.30], [0.08, 10.00, -0.28]]),
        _plane("Spalletta 1", [1, -0.02, 0], [
            [4, 0.00, 0], [4, 0.02, 2], [4.12, 10.00, 1.68], [4.10, 10.02, -0.30]]),
        _plane("Facciata 2", [0, 0.05, 1], [
            [4, 0.02, 2], [8, 0.01, 2], [8.09, 10.01, 1.70], [4.12, 10.00, 1.68]]),
    ]
    out = regularize_planes_document({"planes": planes})
    direction = np.asarray(out["shared_extrusion_direction"])

    sides = []
    for plane in out["planes"]:
        c = np.asarray(plane["corners"])
        side_a = c[3] - c[0]
        side_b = c[2] - c[1]
        assert np.dot(c[1] - c[0], side_a) == pytest.approx(0.0, abs=1e-8)
        assert side_a == pytest.approx(side_b, abs=1e-8)
        assert side_a / np.linalg.norm(side_a) == pytest.approx(direction, abs=1e-8)
        sides.append(side_a)

    assert out["planes"][0]["corners"][1] == pytest.approx(
        out["planes"][1]["corners"][0], abs=1e-8)
    assert out["planes"][0]["corners"][2] == pytest.approx(
        out["planes"][1]["corners"][3], abs=1e-8)
    assert out["planes"][1]["corners"][1] == pytest.approx(
        out["planes"][2]["corners"][0], abs=1e-8)


def test_disconnected_quads_keep_independent_height_ranges():
    first = _plane("Facciata 1", [0, 0, 1], [
        [0, 0, 0], [2, 0, 0], [2, 4, 0], [0, 4, 0]])
    second = _plane("Facciata isolata", [0, 0, 1], [
        [10, 7, 0], [12, 7, 0], [12, 9, 0], [10, 9, 0]])
    out = regularize_planes_document({"planes": [first, second]})
    assert out["planes"] == [first, second]
    assert "shared_extrusion_direction" not in out
