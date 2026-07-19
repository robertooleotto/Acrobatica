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


def test_project_flips_camera_y_into_pixel_y():
    cam = ortho_bake.Camera(
        key="0",
        C=np.array([0.0, 0.0, 1.0]),
        R=np.eye(3),
        fx=100.0,
        fy=100.0,
        cx=64.0,
        cy=64.0,
        image_width=128,
        image_height=128,
    )
    x, y, z = ortho_bake._project(cam, np.array([[0.0, 0.2, 0.0]]))
    assert x[0] == pytest.approx(64.0)
    assert y[0] == pytest.approx(44.0)
    assert z[0] == pytest.approx(1.0)


def test_camera_selection_honors_photo_limit():
    top_cams = np.tile(np.arange(12, dtype=np.int32), (100, 1))
    valid = np.ones(100, dtype=bool)
    kept = ortho_bake._select_cameras(
        top_cams, valid, camera_count=12, max_photos=4,
        min_area_fraction=0.0,
    )
    assert int(kept.sum()) <= 4


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
    source_photo = tmp_path / "source.jpg"
    cv2.imwrite(str(source_photo), image)
    poses = {
        "0": {
            "translation": [0, 0, 1],
            "rotation_wxyz": [1, 0, 0, 0],
            "intrinsics_fx_fy_cx_cy": [100, 100, 64, 64],
        }
    }
    out = tmp_path / "out"
    resolved = []

    def resolve(key):
        resolved.append(key)
        return str(source_photo)

    result = ortho_bake.bake_planes(
        str(mesh), poses, str(photos),
        {"piano_base": {"up": [0, 1, 0]}, "planes": [_plane()]},
        str(out), texel_mm=20, max_photos=4,
        photo_resolver=resolve, available_photo_keys={"0"},
    )
    assert result["count"] == 1
    assert result["coverage"] > 0.98
    assert resolved == ["0"]
    assert (out / "planes_textured.obj").exists()
    assert (out / "planes_textured.mtl").exists()
    texture = cv2.imread(str(out / result["planes"][0]["file"]), cv2.IMREAD_UNCHANGED)
    assert texture.shape[2] == 4
    assert float(texture[..., 2][texture[..., 3] > 0].mean()) > 240
    assert "map_Kd plane_1_facciata.png" in (out / "planes_textured.mtl").read_text()


def test_textured_mesh_welds_shared_positions_but_keeps_separate_uvs(tmp_path):
    def frame(corners):
        points = np.asarray(corners, dtype=float)
        return ortho_bake.PlaneFrame(
            origin=points[0], u=np.array([1.0, 0.0, 0.0]),
            v=np.array([0.0, 1.0, 0.0]), corners=points,
            polygon_uv=np.array([[0, 0], [1, 0], [1, 1], [0, 1]], dtype=float),
            width_world=1.0, height_world=1.0, width_m=1.0, height_m=1.0,
            area_m2=1.0, tex_w=64, tex_h=64, texel_m=0.02,
        )

    first = frame([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]])
    second = frame([[1, 0, 0], [1, 0, 1], [1, 1, 1], [1, 1, 0]])
    ortho_bake._write_textured_mesh(
        str(tmp_path),
        [(1, "facciata", "first.png", first),
         (2, "spalletta", "second.png", second)],
    )

    lines = (tmp_path / "planes_textured.obj").read_text().splitlines()
    assert len([line for line in lines if line.startswith("v ")]) == 6
    assert len([line for line in lines if line.startswith("vt ")]) == 8
    faces = [line for line in lines if line.startswith("f ")]
    assert any(token.startswith("2/") for token in faces[0].split()[1:])
    assert any(token.startswith("2/") for line in faces[2:] for token in line.split()[1:])


def test_seal_texture_edges_removes_transparent_sampling_gap():
    image = np.zeros((9, 9, 4), np.uint8)
    image[2:7, 2:7, :3] = (20, 80, 160)
    image[2:7, 2:7, 3] = 255

    sealed = ortho_bake.seal_texture_edges(image)

    assert np.all(sealed[..., 3] == 255)
    assert np.any(sealed[0, 0, :3] != 0)

    empty = np.zeros((4, 4, 4), np.uint8)
    assert np.array_equal(ortho_bake.seal_texture_edges(empty), empty)
