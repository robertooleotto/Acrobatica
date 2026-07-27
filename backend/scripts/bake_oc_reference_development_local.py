#!/usr/bin/env python3
"""Bake every reviewed plane and unfold its Blend texture into one facade strip."""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

from app.services import ortho_bake as ob
from scripts import run_oc_reference_registration_local as registration


@dataclass
class PlaneLayout:
    plane_id: int
    index: int
    name: str
    role: str
    image_path: Path
    image_width: int
    image_height: int
    min_up: float
    max_up: float
    topology_sides: list[np.ndarray]
    image_side_for_topology_side: list[int]
    rectification_quad_px: np.ndarray | None = None


def _compositing_command(args, plane_id: int, output: Path) -> list[str]:
    return [
        sys.executable, "-u", "-m", "scripts.run_oc_reference_registration_local",
        "--mesh", str(args.mesh),
        "--mtl", str(args.mtl),
        "--planes", str(args.planes),
        "--poses", str(args.poses),
        "--photos", str(args.photos),
        "--out", str(output),
        "--plane-id", str(plane_id),
        "--texel-mm", str(args.texel_mm),
        "--target-height-px", str(args.target_height_px),
        "--scale", str(args.scale),
        "--max-photos", str(args.max_photos),
        "--coverage-photos", str(args.registration_ceiling),
    ]


def bake_planes_with_compositing_engine(args, planes_document: dict) -> dict:
    """Calcola ogni atlante con lo stesso runner della tab Compositing/Blend."""
    vertices, faces = ob.load_obj(str(args.mesh))
    up = np.array([0.0, 1.0, 0.0], float)
    backend = Path(__file__).resolve().parents[1]
    results = []
    reports = []
    total_area = 0.0

    for index, plane in enumerate(planes_document.get("planes", []), 1):
        plane_id = int(plane.get("id", index - 1))
        name = str(plane.get("nome") or plane.get("tipo") or f"Piano {index}")
        print(f"Piano {index}: Compositing Blend ({name})", flush=True)
        with tempfile.TemporaryDirectory(
            prefix=f".plane_{plane_id}_compositing_", dir=args.out,
        ) as temporary:
            temporary_output = Path(temporary)
            subprocess.run(
                _compositing_command(args, plane_id, temporary_output),
                cwd=backend,
                check=True,
            )
            report = json.loads((temporary_output / "report.json").read_text())
            source = temporary_output / "03_registered_mosaic_blend.png"
            if not source.exists():
                raise RuntimeError(f"Blend mancante per il piano {plane_id}")
            filename = f"plane_{index}_{ob._sanitize(name)}.png"
            shutil.copy2(source, args.out / filename)

        frame = ob.plane_frame(
            plane, up, vertices, faces, args.texel_mm / 1000.0,
            scale_m_per_mesh_unit=args.scale,
        )
        if frame is None:
            raise RuntimeError(f"Piano {plane_id} degenere")
        accepted = int(report.get("accepted_photos", 0))
        registered = sum(
            1 for item in report.get("photos", [])
            if isinstance(item.get("registration"), dict)
            and item["registration"].get("accepted")
            and not item["registration"].get("pose_only_filler")
        )
        coverage = float(report.get("registered_planar_coverage", 0.0))
        total_area += frame.area_m2
        results.append({
            "index": index,
            "plane_id": plane_id,
            "nome": name,
            "file": filename,
            "width_m": round(frame.width_m, 3),
            "height_m": round(frame.height_m, 3),
            "tex_w": int(report["size_px"][0]),
            "tex_h": int(report["size_px"][1]),
            "area_m2": round(frame.area_m2, 2),
            "coverage": round(coverage, 3),
            "photos_used": accepted,
            "registered_photos": registered,
            "projection_mode": "compositing_blend",
            "texture_frame": "geometry",
        })
        reports.append({
            "index": index,
            "nome": name,
            "engine": "scripts.run_oc_reference_registration_local",
            **report,
        })

    (args.out / "_registration.json").write_text(json.dumps({
        "schema": "acro.compositing-blend-batch/v1",
        "planes": reports,
    }, indent=2, ensure_ascii=False))
    weighted_coverage = (
        sum(item["coverage"] * item["area_m2"] for item in results) / total_area
        if total_area > 0 else 0.0
    )
    return {
        "planes": results,
        "total_area_m2": round(total_area, 2),
        "coverage": round(weighted_coverage, 3),
        "count": len(results),
        "projection_mode": "compositing_blend",
        "texture_encoding": "sRGB",
    }


def import_compositing_result(
    args, planes_document: dict, summary: dict, source_output: Path,
) -> dict:
    """Aggiorna un atlante del batch con il Blend appena calcolato nella sua tab."""
    report_path = source_output / "report.json"
    blend_path = source_output / "03_registered_mosaic_blend.png"
    if not report_path.exists() or not blend_path.exists():
        raise RuntimeError("Output Compositing Blend incompleto")
    report = json.loads(report_path.read_text())
    plane_id = int(report["plane_id"])
    planes = planes_document.get("planes", [])
    match = next(
        ((index, plane) for index, plane in enumerate(planes, 1)
         if int(plane.get("id", index - 1)) == plane_id),
        None,
    )
    if match is None:
        raise RuntimeError(f"Piano {plane_id} non presente nello sviluppo")
    index, plane = match
    name = str(plane.get("nome") or plane.get("tipo") or f"Piano {index}")
    filename = f"plane_{index}_{ob._sanitize(name)}.png"
    shutil.copy2(blend_path, args.out / filename)

    vertices, faces = ob.load_obj(str(args.mesh))
    frame = ob.plane_frame(
        plane, np.array([0.0, 1.0, 0.0]), vertices, faces,
        float(report.get("texel_mm", args.texel_mm)) / 1000.0,
        scale_m_per_mesh_unit=args.scale,
    )
    if frame is None:
        raise RuntimeError(f"Piano {plane_id} degenere")
    registered = sum(
        1 for item in report.get("photos", [])
        if isinstance(item.get("registration"), dict)
        and item["registration"].get("accepted")
        and not item["registration"].get("pose_only_filler")
    )
    item = {
        "index": index,
        "plane_id": plane_id,
        "nome": name,
        "file": filename,
        "width_m": round(frame.width_m, 3),
        "height_m": round(frame.height_m, 3),
        "tex_w": int(report["size_px"][0]),
        "tex_h": int(report["size_px"][1]),
        "area_m2": round(frame.area_m2, 2),
        "coverage": round(float(report.get("registered_planar_coverage", 0.0)), 3),
        "photos_used": int(report.get("accepted_photos", 0)),
        "registered_photos": registered,
        "projection_mode": "compositing_blend",
        "texture_frame": "geometry",
    }
    current = summary.get("planes", [])
    replaced = False
    for position, existing in enumerate(current):
        existing_id = int(existing.get("plane_id", int(existing["index"]) - 1))
        if existing_id == plane_id:
            current[position] = item
            replaced = True
            break
    if not replaced:
        current.append(item)
        current.sort(key=lambda value: int(value["index"]))
    summary["planes"] = current
    summary["projection_mode"] = "compositing_blend"

    registration_path = args.out / "_registration.json"
    registration_doc = (
        json.loads(registration_path.read_text())
        if registration_path.exists()
        else {"schema": "acro.compositing-blend-batch/v1", "planes": []}
    )
    reports = registration_doc.setdefault("planes", [])
    imported_report = {
        "index": index, "nome": name,
        "engine": "scripts.run_oc_reference_registration_local", **report,
    }
    for position, existing in enumerate(reports):
        existing_id = int(existing.get("plane_id", int(existing.get("index", 1)) - 1))
        if existing_id == plane_id:
            reports[position] = imported_report
            break
    else:
        reports.append(imported_report)
    registration_path.write_text(json.dumps(
        registration_doc, indent=2, ensure_ascii=False,
    ))
    return summary


def _vertical_sides(corners: np.ndarray, up: np.ndarray) -> list[np.ndarray]:
    candidates = []
    for index in range(len(corners)):
        edge = np.stack([corners[index], corners[(index + 1) % len(corners)]])
        direction = edge[1] - edge[0]
        length = float(np.linalg.norm(direction))
        score = abs(float(direction @ up)) / max(length, 1e-9)
        candidates.append((score, edge))
    return [edge for _, edge in sorted(candidates, key=lambda item: item[0], reverse=True)[:2]]


def _average_horizontal_width(corners: np.ndarray, up: np.ndarray, scale: float) -> float:
    candidates = []
    for index in range(len(corners)):
        direction = corners[(index + 1) % len(corners)] - corners[index]
        length = float(np.linalg.norm(direction))
        vertical_score = abs(float(direction @ up)) / max(length, 1e-9)
        candidates.append((vertical_score, length))
    horizontal = sorted(candidates, key=lambda item: item[0])[:2]
    return float(np.mean([length for _, length in horizontal]) * scale)


def _ordered_quad_pixels(polygon_uv: np.ndarray, width: int, height: int) -> np.ndarray | None:
    if polygon_uv.shape != (4, 2):
        return None
    bottom = polygon_uv[np.argsort(polygon_uv[:, 1])[:2]]
    top = polygon_uv[np.argsort(polygon_uv[:, 1])[-2:]]
    bottom = bottom[np.argsort(bottom[:, 0])]
    top = top[np.argsort(top[:, 0])]
    ordered_uv = np.asarray([bottom[0], bottom[1], top[1], top[0]], np.float32)
    return np.column_stack((
        ordered_uv[:, 0] * max(width - 1, 1),
        (1.0 - ordered_uv[:, 1]) * max(height - 1, 1),
    )).astype(np.float32)


def _rectify_image(image: np.ndarray, layout: PlaneLayout) -> np.ndarray:
    source = layout.rectification_quad_px
    if source is None:
        return image
    width, height = layout.image_width, layout.image_height
    # Rettifica soltanto X. Una omografia completa rende rettangolare il quad,
    # ma varia anche Y lungo la larghezza e spezza cornicioni e marcapiani sulle
    # giunzioni. Qui ogni riga conserva esattamente la quota dell'atlante Blend.
    row_t = np.linspace(0.0, 1.0, height, dtype=np.float32)
    left_x = source[3, 0] * (1.0 - row_t) + source[0, 0] * row_t
    right_x = source[2, 0] * (1.0 - row_t) + source[1, 0] * row_t
    column_t = np.linspace(0.0, 1.0, width, dtype=np.float32)
    map_x = left_x[:, None] * (1.0 - column_t) + right_x[:, None] * column_t
    map_y = np.broadcast_to(
        np.arange(height, dtype=np.float32)[:, None], (height, width),
    ).copy()
    return cv2.remap(
        image, map_x.astype(np.float32), map_y, cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0, 0),
    )


def _estimate_horizontal_level_shift(image: np.ndarray) -> tuple[int, float]:
    """Stima quanto le fasce orizzontali scendono da sinistra a destra."""
    height, width = image.shape[:2]
    if height < 40 or width < 30:
        return 0, 0.0
    gray = cv2.cvtColor(image[..., :3], cv2.COLOR_BGR2GRAY).astype(np.float32)
    gradient = np.abs(cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3))
    y0, y1 = int(height * 0.45), int(height * 0.90)
    left = gradient[y0:y1, int(width * 0.12):max(int(width * 0.35), 1)].mean(1)
    right = gradient[y0:y1, int(width * 0.65):max(int(width * 0.88), 1)].mean(1)
    left = cv2.GaussianBlur(left[:, None], (1, 0), 3).ravel()
    right = cv2.GaussianBlur(right[:, None], (1, 0), 3).ravel()
    left = (left - left.mean()) / max(float(left.std()), 1e-6)
    right = (right - right.mean()) / max(float(right.std()), 1e-6)
    strip_center_distance = 0.53
    maximum_shift = max(2, int(round(
        width * strip_center_distance * np.tan(np.radians(5.0)),
    )))
    candidates = []
    for shift in range(-maximum_shift, maximum_shift + 1):
        if shift < 0:
            first, second = left[-shift:], right[:shift]
        elif shift > 0:
            first, second = left[:-shift], right[shift:]
        else:
            first, second = left, right
        candidates.append((float(np.mean(first * second)), shift))
    confidence, strip_shift = max(candidates)
    full_width_shift = int(round(strip_shift / strip_center_distance))
    return (full_width_shift, confidence) if confidence >= 0.35 else (0, confidence)


def _straighten_horizontal_levels(
    image: np.ndarray, shift: int, anchor_side: str,
) -> np.ndarray:
    if shift == 0:
        return image
    height, width = image.shape[:2]
    column = np.linspace(0.0, 1.0, width, dtype=np.float32)
    relative = column if anchor_side == "left" else column - 1.0
    map_x = np.broadcast_to(
        np.arange(width, dtype=np.float32)[None, :], (height, width),
    ).copy()
    map_y = (
        np.arange(height, dtype=np.float32)[:, None]
        + float(shift) * relative[None, :]
    )
    return cv2.remap(
        image, map_x, map_y.astype(np.float32), cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0, 0),
    )


def _edge_distance(first: np.ndarray, second: np.ndarray) -> float:
    direct = np.linalg.norm(first[0] - second[0]) + np.linalg.norm(first[1] - second[1])
    reversed_distance = (
        np.linalg.norm(first[0] - second[1]) + np.linalg.norm(first[1] - second[0])
    )
    return float(min(direct, reversed_distance) * 0.5)


def _plane_frame_sides(
    plane: dict,
    up: np.ndarray,
    vertices: np.ndarray,
    faces: np.ndarray,
    cameras: list[ob.Camera],
    texel_m: float,
    scale: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    frame = ob.plane_frame(
        plane, up, vertices, faces, texel_m,
        scale_m_per_mesh_unit=scale,
    )
    if frame is None:
        raise RuntimeError(f"Piano {plane.get('id')} degenere")
    normal = registration.orient_normal(
        np.asarray(plane["normale"], float), frame.corners.mean(0), cameras,
    )
    registration.orient_frame_for_front_view(frame, normal)
    vertical_middle = frame.v * frame.height_world * 0.5
    left = frame.origin + vertical_middle
    right = frame.origin + frame.u * frame.width_world + vertical_middle
    return left, right, frame.polygon_uv.copy()


def _build_layouts(
    planes: list[dict],
    summary: dict,
    output: Path,
    mesh: Path,
    poses: dict,
    scale: float,
) -> tuple[list[PlaneLayout], np.ndarray]:
    vertices, faces = ob.load_obj(str(mesh))
    cameras = ob.load_cameras(poses)
    up = np.array([0.0, 1.0, 0.0], float)
    texel_m = float(summary["planes"][0]["width_m"]) / max(
        int(summary["planes"][0]["tex_w"]), 1,
    )
    layouts = []
    for index, (plane, result) in enumerate(zip(planes, summary["planes"]), 1):
        image_path = output / str(result["file"])
        image = cv2.imread(str(image_path), cv2.IMREAD_UNCHANGED)
        if image is None:
            raise RuntimeError(f"Texture Blend non leggibile: {image_path}")
        corners = np.asarray(plane["corners"], float)
        topology_sides = _vertical_sides(corners, up)
        image_left, image_right, polygon_uv = _plane_frame_sides(
            plane, up, vertices, faces, cameras, texel_m, scale,
        )
        topology_midpoints = [side.mean(axis=0) for side in topology_sides]
        mapping = [
            0 if np.linalg.norm(midpoint - image_left) <= np.linalg.norm(midpoint - image_right)
            else 1
            for midpoint in topology_midpoints
        ]
        heights = corners @ up * scale
        role = str(plane.get("envelope_role") or plane.get("tipo") or "plane")
        rectify = role.lower() in {"return", "spalletta"}
        target_width = image.shape[1]
        source_quad = None
        if rectify:
            width_m = _average_horizontal_width(corners, up, scale)
            target_width = max(2, int(round(width_m / texel_m)))
            source_quad = _ordered_quad_pixels(
                polygon_uv, image.shape[1], image.shape[0],
            )
        layouts.append(PlaneLayout(
            plane_id=int(plane.get("id", index - 1)),
            index=index,
            name=str(result.get("nome") or f"Piano {index}"),
            role=role,
            image_path=image_path,
            image_width=target_width,
            image_height=image.shape[0],
            min_up=float(heights.min()),
            max_up=float(heights.max()),
            topology_sides=topology_sides,
            image_side_for_topology_side=mapping,
            rectification_quad_px=source_quad,
        ))
    return layouts, up


def _adjacency(layouts: list[PlaneLayout]) -> list[list[tuple[int, int, int]]]:
    graph: list[list[tuple[int, int, int]]] = [[] for _ in layouts]
    candidates = []
    for first, layout_a in enumerate(layouts):
        for second in range(first + 1, len(layouts)):
            layout_b = layouts[second]
            for side_a, edge_a in enumerate(layout_a.topology_sides):
                for side_b, edge_b in enumerate(layout_b.topology_sides):
                    candidates.append((
                        _edge_distance(edge_a, edge_b),
                        first, side_a, second, side_b,
                    ))
    used_sides: set[tuple[int, int]] = set()
    scale_hint = np.median([
        np.linalg.norm(layout.topology_sides[0].mean(0) - layout.topology_sides[1].mean(0))
        for layout in layouts
    ])
    tolerance = max(float(scale_hint) * 0.04, 1e-4)
    for distance, first, side_a, second, side_b in sorted(candidates):
        if distance > tolerance:
            break
        if (first, side_a) in used_sides or (second, side_b) in used_sides:
            continue
        graph[first].append((second, side_a, side_b))
        graph[second].append((first, side_b, side_a))
        used_sides.add((first, side_a))
        used_sides.add((second, side_b))
    return graph


def _traverse_chain(
    graph: list[list[tuple[int, int, int]]], start: int,
) -> list[tuple[int, int]]:
    order: list[tuple[int, int]] = []
    previous = -1
    current = start
    entering_side = next(
        side for side in (0, 1)
        if all(edge[1] != side for edge in graph[current])
    )
    while current >= 0:
        order.append((current, entering_side))
        outgoing = next((edge for edge in graph[current] if edge[0] != previous), None)
        if outgoing is None:
            break
        neighbour, own_side, neighbour_side = outgoing
        previous, current, entering_side = current, neighbour, neighbour_side
    return order


def _chain_order(layouts: list[PlaneLayout], graph: list[list[tuple[int, int, int]]]) -> list[tuple[int, int]]:
    if any(len(edges) > 2 for edges in graph):
        raise RuntimeError("Topologia ramificata: lo sviluppo lineare non e univoco")
    endpoints = [index for index, edges in enumerate(graph) if len(edges) == 1]
    if len(layouts) == 1:
        return [(0, 0)]
    if len(endpoints) != 2:
        raise RuntimeError("Le facce non formano una catena topologica continua")
    first = _traverse_chain(graph, endpoints[0])
    second = _traverse_chain(graph, endpoints[1])
    if len(first) != len(layouts) or len(second) != len(layouts):
        raise RuntimeError("Alcune facce non sono collegate allo sviluppo")

    main_index = next(
        (
            index for index, layout in enumerate(layouts)
            if layout.role in {"main", "facciata"}
        ),
        0,
    )
    def main_is_unflipped(order: list[tuple[int, int]]) -> bool:
        item = next((item for item in order if item[0] == main_index), None)
        return bool(item and layouts[item[0]].image_side_for_topology_side[item[1]] == 0)
    return first if main_is_unflipped(first) else second


def compose_development(
    planes: list[dict], summary: dict, output: Path,
    mesh: Path, poses: dict, scale: float,
    excluded_plane_ids: set[int] | None = None,
) -> dict:
    layouts, _ = _build_layouts(planes, summary, output, mesh, poses, scale)
    graph = _adjacency(layouts)
    order = _chain_order(layouts, graph)
    excluded_plane_ids = excluded_plane_ids or set()
    order = [
        item for item in order
        if layouts[item[0]].plane_id not in excluded_plane_ids
    ]
    if not order:
        raise RuntimeError("Lo sviluppo non puo essere vuoto")
    global_min_up = min(layout.min_up for layout in layouts)
    global_max_up = max(layout.max_up for layout in layouts)
    pixels_per_meter = max([
        layout.image_height / max(layout.max_up - layout.min_up, 1e-9)
        for layout in layouts
    ])
    base_canvas_height = max(
        int(round((global_max_up - global_min_up) * pixels_per_meter)),
        max(layout.image_height for layout in layouts),
    )
    render_sizes = {}
    for layout_index, _ in order:
        layout = layouts[layout_index]
        height = max(2, int(round(
            (layout.max_up - layout.min_up) * pixels_per_meter,
        )))
        width = max(2, int(round(
            layout.image_width * height / max(layout.image_height, 1),
        )))
        render_sizes[layout_index] = (width, height)
    rendered_images = {}
    level_shifts = {}
    for layout_index, _ in order:
        layout = layouts[layout_index]
        image = cv2.imread(str(layout.image_path), cv2.IMREAD_UNCHANGED)
        if image.shape[2] == 3:
            image = cv2.cvtColor(image, cv2.COLOR_BGR2BGRA)
        image = _rectify_image(image, layout)
        render_width, render_height = render_sizes[layout_index]
        if image.shape[1] != render_width or image.shape[0] != render_height:
            image = cv2.resize(
                image, (render_width, render_height), interpolation=cv2.INTER_LINEAR,
            )
        rendered_images[layout_index] = image
        if layout.role.lower() in {"return", "spalletta"}:
            level_shifts[layout_index] = _estimate_horizontal_level_shift(image)

    main_position = max(
        range(len(order)),
        key=lambda position: (
            layouts[order[position][0]].role.lower() in {"main", "facciata"},
            rendered_images[order[position][0]].shape[1],
        ),
    )
    vertical_offsets = {order[main_position][0]: 0}
    current_offset = 0
    for position in range(main_position - 1, -1, -1):
        layout_index = order[position][0]
        layout = layouts[layout_index]
        vertical_offsets[layout_index] = current_offset
        if layout.role.lower() in {"return", "spalletta"}:
            shift, _ = level_shifts.get(layout_index, (0, 0.0))
            rendered_images[layout_index] = _straighten_horizontal_levels(
                rendered_images[layout_index], shift, "right",
            )
            current_offset += shift
    current_offset = 0
    for position in range(main_position + 1, len(order)):
        layout_index = order[position][0]
        layout = layouts[layout_index]
        vertical_offsets[layout_index] = current_offset
        if layout.role.lower() in {"return", "spalletta"}:
            shift, _ = level_shifts.get(layout_index, (0, 0.0))
            rendered_images[layout_index] = _straighten_horizontal_levels(
                rendered_images[layout_index], shift, "left",
            )
            current_offset -= shift

    minimum_offset = min(vertical_offsets.values())
    maximum_offset = max(vertical_offsets.values())
    canvas_height = base_canvas_height + maximum_offset - minimum_offset
    canvas_width = sum(render_sizes[index][0] for index, _ in order) - max(len(order) - 1, 0)
    front_canvas = np.zeros((canvas_height, canvas_width, 4), np.uint8)
    geometric_canvas = np.zeros((canvas_height, canvas_width, 4), np.uint8)
    manifest_faces = []
    x = 0
    for layout_index, entering_side in order:
        layout = layouts[layout_index]
        image = rendered_images[layout_index]
        geometric_flipped = layout.image_side_for_topology_side[entering_side] == 1
        geometric_image = cv2.flip(image, 1) if geometric_flipped else image
        y = (
            int(round((global_max_up - layout.max_up) * pixels_per_meter))
            + vertical_offsets[layout_index] - minimum_offset
        )
        for canvas, source in (
            (front_canvas, image),
            (geometric_canvas, geometric_image),
        ):
            target = canvas[y:y + source.shape[0], x:x + source.shape[1]]
            alpha = source[..., 3:4].astype(np.float32) / 255.0
            target[..., :3] = (
                source[..., :3].astype(np.float32) * alpha
                + target[..., :3].astype(np.float32) * (1.0 - alpha)
            ).astype(np.uint8)
            target[..., 3] = np.maximum(target[..., 3], source[..., 3])
        manifest_faces.append({
            "id": layout.plane_id,
            "index": layout.index,
            "name": layout.name,
            "role": layout.role,
            "file": layout.image_path.name,
            "x": x,
            "y": y,
            "width": image.shape[1],
            "height": image.shape[0],
            "geometric_horizontal_flipped": geometric_flipped,
            "horizontal_level_shift_px": level_shifts.get(layout_index, (0, 0.0))[0],
            "vertical_offset_px": vertical_offsets[layout_index] - minimum_offset,
        })
        x += image.shape[1] - 1

    image_name = "facade_development_front_blend.png"
    geometric_image_name = "facade_development_geometric_blend.png"
    if not cv2.imwrite(str(output / image_name), front_canvas):
        raise RuntimeError("Impossibile scrivere la vista frontale Blend")
    if not cv2.imwrite(str(output / geometric_image_name), geometric_canvas):
        raise RuntimeError("Impossibile scrivere lo sviluppo geometrico Blend")
    manifest = {
        "schema": "acro.facade-development/v2",
        "image": image_name,
        "front_image": image_name,
        "geometric_image": geometric_image_name,
        "canvas_px": [canvas_width, canvas_height],
        "pixels_per_meter": round(float(pixels_per_meter), 4),
        "plane_order": [layouts[index].plane_id for index, _ in order],
        "excluded_plane_ids": sorted(excluded_plane_ids),
        "faces": manifest_faces,
    }
    (output / "development.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False),
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mesh", type=Path, required=True)
    parser.add_argument("--mtl", type=Path, required=True)
    parser.add_argument("--planes", type=Path, required=True)
    parser.add_argument("--poses", type=Path, required=True)
    parser.add_argument("--photos", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--texel-mm", type=float, default=20.0)
    parser.add_argument("--target-height-px", type=int, default=3000)
    parser.add_argument("--scale", type=float, default=6.0927)
    parser.add_argument("--max-photos", type=int, default=12)
    parser.add_argument("--registration-ceiling", type=int, default=12)
    parser.add_argument("--exclude-plane-id", type=int, action="append", default=[])
    parser.add_argument("--compose-only", action="store_true")
    parser.add_argument("--import-compositing-output", type=Path)
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    poses = json.loads(args.poses.read_text())
    planes_document = registration.load_plane_document(args.planes)
    summary_path = args.out / "batch_summary.json"
    if args.import_compositing_output:
        if not summary_path.exists():
            raise SystemExit("Batch summary mancante")
        summary = import_compositing_result(
            args, planes_document, json.loads(summary_path.read_text()),
            args.import_compositing_output,
        )
        summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    elif args.compose_only:
        if not summary_path.exists():
            raise SystemExit("Atlanti mancanti: calcola prima tutte le facce")
        summary = json.loads(summary_path.read_text())
    else:
        summary = bake_planes_with_compositing_engine(args, planes_document)
        summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    excluded_plane_ids = set(args.exclude_plane_id)
    if args.import_compositing_output and not excluded_plane_ids:
        manifest_path = args.out / "development.json"
        if manifest_path.exists():
            previous = json.loads(manifest_path.read_text())
            excluded_plane_ids = set(previous.get("excluded_plane_ids", []))
    manifest = compose_development(
        planes_document["planes"], summary, args.out,
        args.mesh, poses, args.scale, excluded_plane_ids,
    )
    print(json.dumps({
        "planes": len(manifest["faces"]),
        "canvas_px": manifest["canvas_px"],
        "order": manifest["plane_order"],
    }, indent=2))


if __name__ == "__main__":
    main()
