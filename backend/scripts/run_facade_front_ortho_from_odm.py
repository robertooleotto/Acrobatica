#!/usr/bin/env python3
"""Create a facade-front orthographic preview from an ODM dense point cloud.

This is intentionally a local verification tool, not the production renderer.
It uses ODM's colored dense cloud, estimates a dominant facade plane with PCA,
and splats colored points onto a front-facing 2D canvas.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import laspy
import numpy as np


def _as_uint8_color(las: laspy.LasData) -> np.ndarray:
    rgb = np.vstack([las.red, las.green, las.blue]).T.astype(np.float32)
    if rgb.max() > 255:
        rgb /= 256.0
    return np.clip(rgb, 0, 255).astype(np.uint8)


def _pca_axes(points: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    center = np.median(points, axis=0)
    centered = points - center
    cov = np.cov(centered.T)
    values, vectors = np.linalg.eigh(cov)
    order = np.argsort(values)[::-1]
    axes = vectors[:, order].T

    # For a facade cloud the two largest components span the wall; the smallest
    # component is the viewing normal. Make the vertical axis point upward-ish in
    # ODM's coordinates by preferring the in-plane axis with more Z component.
    u, v, n = axes[0], axes[1], axes[2]
    if abs(u[2]) > abs(v[2]):
        u, v = v, u
    if v[2] < 0:
        v = -v
    if np.cross(u, v).dot(n) < 0:
        u = -u
    return center, u, v, n


def _robust_bounds(values: np.ndarray, low: float = 0.5, high: float = 99.5) -> tuple[float, float]:
    lo, hi = np.percentile(values, [low, high])
    pad = max((hi - lo) * 0.02, 1e-6)
    return float(lo - pad), float(hi + pad)


def render_front_ortho(
    laz_path: Path,
    out_path: Path,
    pixels_per_unit: float,
    max_points: int,
    point_radius: int,
) -> dict[str, object]:
    las = laspy.read(laz_path)
    points = np.vstack([las.x, las.y, las.z]).T.astype(np.float32)
    colors = _as_uint8_color(las)

    if len(points) > max_points:
        rng = np.random.default_rng(42)
        idx = rng.choice(len(points), size=max_points, replace=False)
        points = points[idx]
        colors = colors[idx]

    center, u_axis, v_axis, n_axis = _pca_axes(points)
    rel = points - center
    u = rel @ u_axis
    v = rel @ v_axis
    depth = rel @ n_axis

    u_min, u_max = _robust_bounds(u)
    v_min, v_max = _robust_bounds(v)
    width = int(np.ceil((u_max - u_min) * pixels_per_unit))
    height = int(np.ceil((v_max - v_min) * pixels_per_unit))
    width = max(64, min(width, 8000))
    height = max(64, min(height, 8000))

    x = ((u - u_min) / (u_max - u_min) * (width - 1)).astype(np.int32)
    y = ((v_max - v) / (v_max - v_min) * (height - 1)).astype(np.int32)
    valid = (x >= 0) & (x < width) & (y >= 0) & (y < height)
    x, y, depth, colors = x[valid], y[valid], depth[valid], colors[valid]

    # Front-most splat per pixel first, then dilate/inpaint tiny holes.
    order = np.argsort(depth)
    canvas = np.zeros((height, width, 3), dtype=np.uint8)
    weight = np.zeros((height, width), dtype=np.uint8)
    for px, py, col in zip(x[order], y[order], colors[order]):
        canvas[py, px] = col
        weight[py, px] = 255

    if point_radius > 0:
        kernel = cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (point_radius * 2 + 1, point_radius * 2 + 1)
        )
        canvas = cv2.dilate(canvas, kernel)
        weight = cv2.dilate(weight, kernel)

    missing = cv2.bitwise_not(weight)
    if np.any(missing):
        canvas = cv2.inpaint(canvas, missing, 3, cv2.INPAINT_TELEA)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out_path), cv2.cvtColor(canvas, cv2.COLOR_RGB2BGR))

    return {
        "input_points": int(len(las.points)),
        "rendered_points": int(len(points)),
        "output": str(out_path),
        "size": [width, height],
        "u_range": [u_min, u_max],
        "v_range": [v_min, v_max],
        "center": center.tolist(),
        "u_axis": u_axis.tolist(),
        "v_axis": v_axis.tolist(),
        "normal": n_axis.tolist(),
    }


def _load_mtl(mtl_path: Path) -> dict[str, Path]:
    textures: dict[str, Path] = {}
    current: str | None = None
    for raw in mtl_path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(maxsplit=1)
        if parts[0] == "newmtl" and len(parts) == 2:
            current = parts[1]
        elif parts[0] == "map_Kd" and current and len(parts) == 2:
            textures[current] = mtl_path.parent / parts[1]
    return textures


def _parse_obj(obj_path: Path) -> tuple[np.ndarray, np.ndarray, list[tuple[np.ndarray, np.ndarray, str]]]:
    vertices: list[tuple[float, float, float]] = []
    texcoords: list[tuple[float, float]] = []
    faces: list[tuple[np.ndarray, np.ndarray, str]] = []
    material = ""

    with obj_path.open() as fh:
        for raw in fh:
            if raw.startswith("v "):
                _, x, y, z = raw.split()[:4]
                vertices.append((float(x), float(y), float(z)))
            elif raw.startswith("vt "):
                _, u, v = raw.split()[:3]
                texcoords.append((float(u), float(v)))
            elif raw.startswith("usemtl "):
                material = raw.split(maxsplit=1)[1].strip()
            elif raw.startswith("f "):
                refs = raw.split()[1:]
                if len(refs) != 3:
                    continue
                vi: list[int] = []
                ti: list[int] = []
                for ref in refs:
                    chunks = ref.split("/")
                    vi.append(int(chunks[0]) - 1)
                    ti.append(int(chunks[1]) - 1 if len(chunks) > 1 and chunks[1] else -1)
                faces.append((np.array(vi, dtype=np.int32), np.array(ti, dtype=np.int32), material))

    return np.array(vertices, dtype=np.float32), np.array(texcoords, dtype=np.float32), faces


def render_textured_mesh_front(
    obj_path: Path,
    mtl_path: Path,
    out_path: Path,
    pixels_per_unit: float,
    max_size: int,
    min_area_px: float,
    depth_low_pct: float,
    depth_high_pct: float,
    sample_uv: bool,
) -> dict[str, object]:
    vertices, texcoords, faces = _parse_obj(obj_path)
    center, u_axis, v_axis, n_axis = _pca_axes(vertices)
    rel = vertices - center
    u = rel @ u_axis
    v = rel @ v_axis
    depth = rel @ n_axis

    u_min, u_max = _robust_bounds(u, 0.2, 99.8)
    v_min, v_max = _robust_bounds(v, 0.2, 99.8)
    width = int(np.ceil((u_max - u_min) * pixels_per_unit))
    height = int(np.ceil((v_max - v_min) * pixels_per_unit))
    scale = min(1.0, max_size / max(width, height))
    width = max(64, int(width * scale))
    height = max(64, int(height * scale))

    px = ((u - u_min) / (u_max - u_min) * (width - 1)).astype(np.float32)
    py = ((v_max - v) / (v_max - v_min) * (height - 1)).astype(np.float32)
    projected = np.column_stack([px, py])
    depth_lo, depth_hi = np.percentile(depth, [depth_low_pct, depth_high_pct])

    texture_paths = _load_mtl(mtl_path)
    textures: dict[str, np.ndarray] = {}
    for material, path in texture_paths.items():
        img = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if img is not None:
            textures[material] = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

    face_records: list[tuple[float, np.ndarray, np.ndarray, str]] = []
    for vi, ti, material in faces:
        tri = projected[vi]
        if (
            tri[:, 0].max() < 0
            or tri[:, 0].min() >= width
            or tri[:, 1].max() < 0
            or tri[:, 1].min() >= height
        ):
            continue
        area = abs(np.cross(tri[1] - tri[0], tri[2] - tri[0])) * 0.5
        if area < min_area_px:
            continue
        face_depth = float(depth[vi].mean())
        if face_depth < depth_lo or face_depth > depth_hi:
            continue
        # Cull triangles nearly perpendicular to the virtual facade camera. This
        # reduces noisy side faces at the edges without hiding real front planes.
        p0, p1, p2 = vertices[vi]
        normal = np.cross(p1 - p0, p2 - p0)
        norm = np.linalg.norm(normal)
        if norm < 1e-9:
            continue
        facing = abs(float((normal / norm).dot(n_axis)))
        if facing < 0.18:
            continue
        face_records.append((face_depth, tri, texcoords[ti], material))

    face_records.sort(key=lambda item: item[0], reverse=True)
    canvas = np.full((height, width, 3), 245, dtype=np.uint8)
    coverage = np.zeros((height, width), dtype=np.uint8)

    textured_faces = 0
    for _, tri, uv, material in face_records:
        tex = textures.get(material)
        if tex is None or np.any(uv < 0):
            continue
        pts = np.round(tri).astype(np.int32)
        if not sample_uv:
            uv_mid = uv.mean(axis=0)
            tx = int(np.clip(uv_mid[0], 0.0, 1.0) * (tex.shape[1] - 1))
            ty = int((1.0 - np.clip(uv_mid[1], 0.0, 1.0)) * (tex.shape[0] - 1))
            cv2.fillConvexPoly(canvas, pts, tex[ty, tx].tolist())
            cv2.fillConvexPoly(coverage, pts, 255)
            textured_faces += 1
            continue

        src = np.column_stack(
            [
                np.clip(uv[:, 0], 0.0, 1.0) * (tex.shape[1] - 1),
                (1.0 - np.clip(uv[:, 1], 0.0, 1.0)) * (tex.shape[0] - 1),
            ]
        ).astype(np.float32)
        dst = tri.astype(np.float32)

        x0 = max(0, int(np.floor(dst[:, 0].min())))
        y0 = max(0, int(np.floor(dst[:, 1].min())))
        x1 = min(width, int(np.ceil(dst[:, 0].max())) + 1)
        y1 = min(height, int(np.ceil(dst[:, 1].max())) + 1)
        if x1 <= x0 or y1 <= y0:
            continue

        sx0 = max(0, int(np.floor(src[:, 0].min())) - 2)
        sy0 = max(0, int(np.floor(src[:, 1].min())) - 2)
        sx1 = min(tex.shape[1], int(np.ceil(src[:, 0].max())) + 3)
        sy1 = min(tex.shape[0], int(np.ceil(src[:, 1].max())) + 3)
        if sx1 <= sx0 or sy1 <= sy0:
            continue

        src_local = src - np.array([sx0, sy0], dtype=np.float32)
        dst_local = dst - np.array([x0, y0], dtype=np.float32)
        matrix = cv2.getAffineTransform(src_local, dst_local)
        patch = tex[sy0:sy1, sx0:sx1]
        warped = cv2.warpAffine(
            patch,
            matrix,
            (x1 - x0, y1 - y0),
            flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_REFLECT_101,
        )
        mask = np.zeros((y1 - y0, x1 - x0), dtype=np.uint8)
        cv2.fillConvexPoly(mask, np.round(dst_local).astype(np.int32), 255)
        roi = canvas[y0:y1, x0:x1]
        roi[mask > 0] = warped[mask > 0]
        coverage[y0:y1, x0:x1][mask > 0] = 255
        textured_faces += 1

    missing = cv2.bitwise_not(coverage)
    if np.any(missing):
        canvas = cv2.inpaint(canvas, missing, 3, cv2.INPAINT_TELEA)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out_path), cv2.cvtColor(canvas, cv2.COLOR_RGB2BGR))

    return {
        "vertices": int(len(vertices)),
        "faces": int(len(faces)),
        "rendered_faces": int(len(face_records)),
        "textured_faces": int(textured_faces),
        "output": str(out_path),
        "size": [width, height],
        "center": center.tolist(),
        "u_axis": u_axis.tolist(),
        "v_axis": v_axis.tolist(),
        "normal": n_axis.tolist(),
        "depth_range": [float(depth_lo), float(depth_hi)],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--laz",
        type=Path,
        default=Path(
            "/tmp/odm_53f1b49d_results/extracted/odm_georeferencing/odm_georeferenced_model.laz"
        ),
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("/tmp/odm_53f1b49d_results/facade_front_ortho_points.png"),
    )
    parser.add_argument("--pixels-per-unit", type=float, default=700)
    parser.add_argument("--max-points", type=int, default=2_000_000)
    parser.add_argument("--point-radius", type=int, default=2)
    parser.add_argument("--mode", choices=["points", "mesh"], default="points")
    parser.add_argument(
        "--obj",
        type=Path,
        default=Path("/tmp/odm_53f1b49d_results/extracted/odm_texturing/odm_textured_model_geo.obj"),
    )
    parser.add_argument(
        "--mtl",
        type=Path,
        default=Path("/tmp/odm_53f1b49d_results/extracted/odm_texturing/odm_textured_model_geo.mtl"),
    )
    parser.add_argument("--max-size", type=int, default=3200)
    parser.add_argument("--min-area-px", type=float, default=0.15)
    parser.add_argument("--depth-low-pct", type=float, default=1.0)
    parser.add_argument("--depth-high-pct", type=float, default=99.0)
    parser.add_argument("--sample-uv", action="store_true")
    args = parser.parse_args()

    if args.mode == "points":
        stats = render_front_ortho(
            laz_path=args.laz,
            out_path=args.out,
            pixels_per_unit=args.pixels_per_unit,
            max_points=args.max_points,
            point_radius=args.point_radius,
        )
    else:
        stats = render_textured_mesh_front(
            obj_path=args.obj,
            mtl_path=args.mtl,
            out_path=args.out,
            pixels_per_unit=args.pixels_per_unit,
            max_size=args.max_size,
            min_area_px=args.min_area_px,
            depth_low_pct=args.depth_low_pct,
            depth_high_pct=args.depth_high_pct,
            sample_uv=args.sample_uv,
        )
    for key, value in stats.items():
        print(f"{key}: {value}")


if __name__ == "__main__":
    main()
