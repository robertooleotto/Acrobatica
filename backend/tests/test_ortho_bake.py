from pathlib import Path

import cv2
import numpy as np
import pytest

from app.services import ortho_bake


def _write_mesh(path: Path):
    path.write_text(
        "v -2 -2 0\n"
        "v 2 -2 0\n"
        "v 2 2 0\n"
        "v -2 2 0\n"
        "f 1 2 3\n"
        "f 1 3 4\n"
    )


def _plane():
    return {
        "nome": "facciata",
        "punto": [0, 0, 0],
        "normale": [0, 0, 1],
        "corners": [
            [-0.3, -0.3, 0], [0.3, -0.3, 0],
            [0.3, 0.3, 0], [-0.3, 0.3, 0],
        ],
        "triangoli": [0, 1],
    }


def test_plane_frame_prefers_reviewed_corners_over_support_triangles(tmp_path):
    mesh = tmp_path / "mesh.obj"
    _write_mesh(mesh)
    vertices, faces = ortho_bake.load_obj(mesh)
    frame = ortho_bake.plane_frame(
        _plane(), np.array([0, 1, 0.0]), vertices, faces, 0.01,
        scale_m_per_mesh_unit=2.0,
    )
    assert frame is not None
    assert frame.width_world == pytest.approx(0.6)
    assert frame.height_world == pytest.approx(0.6)
    assert frame.width_m == pytest.approx(1.2)
    assert frame.area_m2 == pytest.approx(1.44)


def test_bake_writes_textured_plane_bundle(tmp_path):
    mesh = tmp_path / "mesh.obj"
    _write_mesh(mesh)
    photos = tmp_path / "photos"
    photos.mkdir()
    image = np.zeros((128, 128, 3), np.uint8)
    image[:] = (0, 0, 255)
    cv2.imwrite(str(photos / "0000.jpg"), image)
    poses = {
        "0": {
            "translation": [0, 0, 1],
            "rotation_wxyz": [1, 0, 0, 0],
            "intrinsics_fx_fy_cx_cy": [100, 100, 64, 64],
        }
    }
    out = tmp_path / "out"
    result = ortho_bake.bake_planes(
        str(mesh), poses, str(photos),
        {"piano_base": {"up": [0, 1, 0]}, "planes": [_plane()]},
        str(out), texel_mm=20, max_photos=4,
    )
    assert result["count"] == 1
    assert result["coverage"] > 0.98
    assert (out / "planes_textured.obj").exists()
    assert (out / "planes_textured.mtl").exists()
    texture = cv2.imread(str(out / result["planes"][0]["file"]), cv2.IMREAD_UNCHANGED)
    assert texture.shape[2] == 4
    assert float(texture[..., 2][texture[..., 3] > 0].mean()) > 240
    assert "map_Kd plane_1_facciata.png" in (out / "planes_textured.mtl").read_text()
