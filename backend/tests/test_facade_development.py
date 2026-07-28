from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np

from scripts import bake_oc_reference_development_local as development


def _side(x: float) -> np.ndarray:
    return np.array([[x, 0.0, 0.0], [x, 3.0, 0.0]], float)


def _layout(
    plane_id: int,
    role: str,
    left: float,
    right: float,
    mapping: list[int],
) -> development.PlaneLayout:
    return development.PlaneLayout(
        plane_id=plane_id,
        index=plane_id + 1,
        name=f"Piano {plane_id + 1}",
        role=role,
        image_path=Path("unused.png"),
        image_width=100,
        image_height=300,
        min_up=0.0,
        max_up=3.0,
        topology_sides=[_side(left), _side(right)],
        image_side_for_topology_side=mapping,
    )


def test_development_orders_a_topological_chain_and_keeps_main_unflipped():
    layouts = [
        _layout(0, "return", 0.0, 1.0, [0, 1]),
        _layout(1, "main", 1.0, 3.0, [0, 1]),
        _layout(2, "return", 3.0, 4.0, [0, 1]),
    ]

    graph = development._adjacency(layouts)
    order = development._chain_order(layouts, graph)

    assert [layouts[index].plane_id for index, _ in order] == [0, 1, 2]
    main_index, entering_side = order[1]
    assert layouts[main_index].image_side_for_topology_side[entering_side] == 0


def test_development_reverses_chain_when_main_texture_would_be_mirrored():
    layouts = [
        _layout(0, "return", 0.0, 1.0, [0, 1]),
        _layout(1, "main", 1.0, 3.0, [1, 0]),
        _layout(2, "return", 3.0, 4.0, [0, 1]),
    ]

    order = development._chain_order(layouts, development._adjacency(layouts))
    main_index, entering_side = next(item for item in order if item[0] == 1)

    assert layouts[main_index].image_side_for_topology_side[entering_side] == 0


def test_geometric_flip_is_independent_from_front_facing_texture():
    layout = _layout(0, "return", 0.0, 1.0, [1, 0])

    entering_side = 0

    assert layout.image_side_for_topology_side[entering_side] == 1


def test_development_uses_the_compositing_blend_runner_for_each_plane():
    args = SimpleNamespace(
        mesh=Path("mesh.obj"), mtl=Path("mesh.mtl"), planes=Path("planes.json"),
        poses=Path("poses.json"), photos=Path("photos"), texel_mm=20.0,
        target_height_px=3000, scale=6.0927, max_photos=20,
        registration_ceiling=60,
    )

    command = development._compositing_command(args, 7, Path("output"))

    assert command[2:4] == ["-m", "scripts.run_oc_reference_registration_local"]
    assert command[command.index("--plane-id") + 1] == "7"
    assert command[command.index("--max-photos") + 1] == "20"
    assert command[command.index("--coverage-photos") + 1] == "60"
    assert command[command.index("--target-height-px") + 1] == "3000"


def test_return_width_uses_the_mean_of_top_and_bottom_edges():
    corners = np.array([
        [0.0, 0.0, 0.0], [2.0, 0.0, 0.0],
        [1.8, 3.0, 0.0], [0.0, 3.0, 0.0],
    ])

    width = development._average_horizontal_width(
        corners, np.array([0.0, 1.0, 0.0]), 1.0,
    )

    assert width == 1.9


def test_return_quad_is_ordered_bottom_left_clockwise_in_image_space():
    polygon_uv = np.array([
        [1.0, 0.0], [0.2, 0.0], [0.0, 1.0], [0.7, 1.0],
    ])

    quad = development._ordered_quad_pixels(polygon_uv, 101, 201)

    assert np.allclose(quad, [
        [20.0, 200.0], [100.0, 200.0], [70.0, 0.0], [0.0, 0.0],
    ])


def test_return_rectification_preserves_every_horizontal_level():
    image = np.zeros((101, 121, 4), np.uint8)
    image[:, :, 3] = 255
    image[37, :, :3] = 255
    layout = _layout(0, "return", 0.0, 1.0, [0, 1])
    layout.image_width = 91
    layout.image_height = 101
    layout.rectification_quad_px = np.array([
        [20.0, 100.0], [120.0, 100.0], [100.0, 0.0], [0.0, 0.0],
    ], np.float32)

    rectified = development._rectify_image(image, layout)

    assert rectified.shape == (101, 91, 4)
    assert int(rectified[37, :, :3].mean()) == 255
    assert int(rectified[36, :, :3].max()) == 0
    assert int(rectified[38, :, :3].max()) == 0


def test_level_shear_flattens_a_sloped_horizontal_band_at_left_anchor():
    image = np.zeros((120, 100, 4), np.uint8)
    image[:, :, 3] = 255
    for x in range(100):
        image[40 + round(6 * x / 99), x, :3] = 255

    straightened = development._straighten_horizontal_levels(image, 6, "left")

    brightest_row = np.argmax(straightened[..., :3].mean(axis=(1, 2)))
    assert brightest_row == 40


def test_development_exports_rectified_texture_for_every_face(monkeypatch, tmp_path):
    image = np.full((30, 20, 4), 180, np.uint8)
    first_path = tmp_path / "plane_1.png"
    second_path = tmp_path / "plane_2.png"
    assert cv2.imwrite(str(first_path), image)
    assert cv2.imwrite(str(second_path), image)
    layouts = [
        _layout(0, "main", 0.0, 1.0, [0, 1]),
        _layout(1, "main", 1.0, 2.0, [0, 1]),
    ]
    layouts[0].image_path = first_path
    layouts[1].image_path = second_path
    layouts[0].image_width = layouts[1].image_width = 20
    layouts[0].image_height = layouts[1].image_height = 30
    monkeypatch.setattr(
        development, "_build_layouts",
        lambda *args, **kwargs: (layouts, np.array([0.0, 1.0, 0.0])),
    )

    manifest = development.compose_development(
        [], {"planes": []}, tmp_path, Path("mesh.obj"), {}, 1.0,
    )

    assert manifest["plane_order"] == [0, 1]
    assert [face["development_file"] for face in manifest["faces"]] == [
        "development_plane_1.png", "development_plane_2.png",
    ]
    assert (tmp_path / "development_plane_1.png").exists()
    assert (tmp_path / "development_plane_2.png").exists()
