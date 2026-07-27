"""Test del detector balconi basato su soletta e parapetto della mesh."""
import numpy as np

from app.services.balcony_mesh_geometry import detect_balconies_from_mesh


PLANE = {
    "c": [0.0, 0.0, 0.0],
    "n": [0.0, 0.0, 1.0],
    "up": [0.0, 1.0, 0.0],
    "right": [1.0, 0.0, 0.0],
    "bounds": [-5.0, 5.0, 0.0, 10.0],
}


def _add_box(vertices, faces, x0, x1, y0, y1, z0, z1):
    offset = len(vertices)
    vertices.extend([
        [x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1],
        [x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1],
    ])
    quads = [
        [0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
        [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7],
    ]
    for a, b, c, d in quads:
        faces.extend([[offset + a, offset + b, offset + c],
                      [offset + a, offset + c, offset + d]])


def _scene(include_parapet=True):
    vertices, faces = [], []
    # Soletta reale: 1.8 m di larghezza, 0.8 m di profondità.
    _add_box(vertices, faces, -0.9, 0.9, 2.82, 3.0, 0.0, 0.8)
    if include_parapet:
        _add_box(vertices, faces, -0.9, 0.9, 3.0, 4.0, 0.72, 0.8)
    # Cornice: sporge troppo poco e non ha parapetto.
    _add_box(vertices, faces, -3.0, 3.0, 5.0, 5.15, 0.0, 0.25)
    return np.asarray(vertices, float), np.asarray(faces, int)


def test_detects_slab_with_parapet_and_builds_correct_geometry():
    vertices, faces = _scene()
    result = detect_balconies_from_mesh(vertices, faces, PLANE)

    assert result["count"] == 1
    balcony = result["balconies"][0]
    assert balcony["width_m"] == 1.8
    assert balcony["projection_depth_m"] == 0.8
    assert balcony["parapet_height_m"] >= 0.7
    # Due box (soletta + parapetto), 8 vertici e 6 facce ciascuno.
    assert result["model_json"]["n_vertices"] == 16
    assert result["model_json"]["n_faces"] == 12


def test_rejects_slab_without_parapet_and_shallow_cornice():
    vertices, faces = _scene(include_parapet=False)
    result = detect_balconies_from_mesh(vertices, faces, PLANE)
    assert result["count"] == 0
