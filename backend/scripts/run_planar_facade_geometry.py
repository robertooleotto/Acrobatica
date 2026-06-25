#!/usr/bin/env python3
"""Estimate a clean planar 2.5D facade geometry from ARKit sparse points.

Output is not a noisy photogrammetry mesh. It is a simplified architectural
model: main facade plane plus planar extrusion boxes for out-of-plane clusters
(for example bow-windows).
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

import cv2
import numpy as np
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
load_dotenv(ROOT / ".env")

from _session_source import SessionSource
from run_flat_facade_ortho_from_arkit import estimate_plane, load_ply


@dataclass
class PlanePatch:
    name: str
    kind: str
    origin: tuple[float, float, float]
    right: tuple[float, float, float]
    up: tuple[float, float, float]
    normal: tuple[float, float, float]
    width_m: float
    height_m: float
    depth_m: float
    u_min: float
    u_max: float
    v_min: float
    v_max: float
    point_count: int


def _world(point: np.ndarray, right: np.ndarray, up: np.ndarray, normal: np.ndarray, u: float, v: float, d: float) -> np.ndarray:
    return point + right * u + up * v + normal * d


def _component_clusters(
    u: np.ndarray,
    v: np.ndarray,
    d: np.ndarray,
    *,
    u_min: float,
    u_max: float,
    v_min: float,
    v_max: float,
    depth_threshold: float,
    cell_m: float,
    min_points: int,
    close_iterations: int,
    dilate_iterations: int,
    split_gap_m: float,
) -> list[np.ndarray]:
    sel = (
        (u >= u_min)
        & (u <= u_max)
        & (v >= v_min)
        & (v <= v_max)
        & (d > depth_threshold)
    )
    idx = np.where(sel)[0]
    if len(idx) == 0:
        return []

    width = int(np.ceil((u_max - u_min) / cell_m)) + 1
    height = int(np.ceil((v_max - v_min) / cell_m)) + 1
    gx = np.clip(((u[idx] - u_min) / cell_m).astype(np.int32), 0, width - 1)
    gy = np.clip(((v_max - v[idx]) / cell_m).astype(np.int32), 0, height - 1)

    occ = np.zeros((height, width), dtype=np.uint8)
    occ[gy, gx] = 255
    if close_iterations > 0:
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        occ = cv2.morphologyEx(occ, cv2.MORPH_CLOSE, kernel, iterations=close_iterations)
    if dilate_iterations > 0:
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        occ = cv2.dilate(occ, kernel, iterations=dilate_iterations)
    n_labels, labels = cv2.connectedComponents(occ)

    clusters: list[np.ndarray] = []
    point_labels = labels[gy, gx]
    for lab in range(1, n_labels):
        pts_idx = idx[point_labels == lab]
        if len(pts_idx) < min_points:
            continue

        pieces = [pts_idx]
        if split_gap_m > 0:
            pieces = _split_by_projection_gaps(pieces, u, min_points, split_gap_m)
            pieces = _split_by_projection_gaps(pieces, v, min_points, split_gap_m)

        clusters.extend(piece for piece in pieces if len(piece) >= min_points)
    clusters.sort(key=len, reverse=True)
    return clusters


def _split_by_projection_gaps(
    clusters: list[np.ndarray],
    coord: np.ndarray,
    min_points: int,
    gap_m: float,
) -> list[np.ndarray]:
    out: list[np.ndarray] = []
    for idx in clusters:
        order = idx[np.argsort(coord[idx])]
        values = coord[order]
        gaps = np.where(np.diff(values) > gap_m)[0]
        if len(gaps) == 0:
            out.append(idx)
            continue

        start = 0
        for gap in gaps:
            piece = order[start : gap + 1]
            if len(piece) >= min_points:
                out.append(piece)
            start = gap + 1
        piece = order[start:]
        if len(piece) >= min_points:
            out.append(piece)
    return out


def _make_extrusion_patches(
    cluster_id: int,
    idx: np.ndarray,
    point: np.ndarray,
    right: np.ndarray,
    up: np.ndarray,
    normal: np.ndarray,
    u: np.ndarray,
    v: np.ndarray,
    d: np.ndarray,
    *,
    min_size_m: float,
    pad_m: float,
) -> list[PlanePatch]:
    cu, cv, cd = u[idx], v[idx], d[idx]
    u0, u1 = np.percentile(cu, [2, 98])
    v0, v1 = np.percentile(cv, [2, 98])
    depth = float(np.percentile(cd, 65))
    if (u1 - u0) < min_size_m or (v1 - v0) < min_size_m or depth < 0.1:
        return []
    u0 -= pad_m
    u1 += pad_m
    v0 -= pad_m
    v1 += pad_m
    width = float(u1 - u0)
    height = float(v1 - v0)
    name = f"secondary_{cluster_id:02d}"

    front_origin = _world(point, right, up, normal, u0, v0, depth)
    side_l_origin = _world(point, right, up, normal, u0, v0, 0.0)
    side_r_origin = _world(point, right, up, normal, u1, v0, 0.0)

    patches = [
        PlanePatch(
            name=f"{name}_front",
            kind="front",
            origin=tuple(front_origin.tolist()),
            right=tuple(right.tolist()),
            up=tuple(up.tolist()),
            normal=tuple(normal.tolist()),
            width_m=width,
            height_m=height,
            depth_m=depth,
            u_min=float(u0),
            u_max=float(u1),
            v_min=float(v0),
            v_max=float(v1),
            point_count=int(len(idx)),
        ),
        PlanePatch(
            name=f"{name}_left",
            kind="side",
            origin=tuple(side_l_origin.tolist()),
            right=tuple(normal.tolist()),
            up=tuple(up.tolist()),
            normal=tuple((-right).tolist()),
            width_m=depth,
            height_m=height,
            depth_m=depth,
            u_min=float(u0),
            u_max=float(u0),
            v_min=float(v0),
            v_max=float(v1),
            point_count=int(len(idx)),
        ),
        PlanePatch(
            name=f"{name}_right",
            kind="side",
            origin=tuple(side_r_origin.tolist()),
            right=tuple(normal.tolist()),
            up=tuple(up.tolist()),
            normal=tuple(right.tolist()),
            width_m=depth,
            height_m=height,
            depth_m=depth,
            u_min=float(u1),
            u_max=float(u1),
            v_min=float(v0),
            v_max=float(v1),
            point_count=int(len(idx)),
        ),
    ]
    return patches


def write_obj(path: Path, main_patch: PlanePatch, patches: list[PlanePatch]) -> None:
    all_patches = [main_patch] + patches
    colors = {
        "main": "0.80 0.80 0.78",
        "front": "0.95 0.72 0.25",
        "side": "0.35 0.62 0.95",
    }
    mtl = path.with_suffix(".mtl")
    with mtl.open("w") as f:
        for key, color in colors.items():
            f.write(f"newmtl {key}\nKd {color}\nKa {color}\nKs 0.000 0.000 0.000\n\n")

    with path.open("w") as f:
        f.write(f"mtllib {mtl.name}\n")
        vi = 1
        for patch in all_patches:
            o = np.asarray(patch.origin)
            r = np.asarray(patch.right) * patch.width_m
            u = np.asarray(patch.up) * patch.height_m
            verts = [o, o + r, o + r + u, o + u]
            f.write(f"o {patch.name}\nusemtl {patch.kind}\n")
            for vtx in verts:
                f.write(f"v {vtx[0]:.6f} {vtx[1]:.6f} {vtx[2]:.6f}\n")
            f.write(f"f {vi} {vi+1} {vi+2} {vi+3}\n")
            vi += 4


def draw_report(
    out: Path,
    plane,
    patches: list[PlanePatch],
    u: np.ndarray,
    v: np.ndarray,
    d: np.ndarray,
    clusters: list[np.ndarray],
) -> None:
    W, H = 1800, 1300
    sheet = np.full((H, W, 3), 246, dtype=np.uint8)
    panel_w, panel_h = 900, 650

    def make_panel(title: str, x: np.ndarray, y: np.ndarray, xlabel: str, ylabel: str) -> np.ndarray:
        img = np.full((panel_h, panel_w, 3), 248, dtype=np.uint8)
        margin = 70
        xs = [float(np.percentile(x, 0.5)), float(np.percentile(x, 99.5)), plane.u_min, plane.u_max]
        ys = [float(np.percentile(y, 0.5)), float(np.percentile(y, 99.5)), plane.v_min, plane.v_max]
        if ylabel.startswith("depth"):
            ys = [float(np.percentile(y, 0.5)), float(np.percentile(y, 99.5)), 0.0]
        xmin, xmax = min(xs), max(xs)
        ymin, ymax = min(ys), max(ys)
        padx, pady = (xmax - xmin) * 0.08, (ymax - ymin) * 0.08
        xmin, xmax, ymin, ymax = xmin - padx, xmax + padx, ymin - pady, ymax + pady

        def tr(a, b):
            px = margin + (a - xmin) / max(xmax - xmin, 1e-9) * (panel_w - 2 * margin)
            py = panel_h - margin - (b - ymin) / max(ymax - ymin, 1e-9) * (panel_h - 2 * margin)
            return np.column_stack([px, py]).astype(np.int32)

        cv2.rectangle(img, (margin, margin), (panel_w - margin, panel_h - margin), (215, 215, 215), 1)
        pts = tr(x, y)
        for px, py in pts:
            if margin <= px < panel_w - margin and margin <= py < panel_h - margin:
                img[py, px] = (105, 105, 105)

        palette = [(30, 120, 240), (255, 135, 20), (50, 180, 80), (180, 80, 220), (40, 190, 210)]
        for ci, idx in enumerate(clusters[:5]):
            color = palette[ci % len(palette)]
            pts = tr(x[idx], y[idx])
            for px, py in pts:
                if margin <= px < panel_w - margin and margin <= py < panel_h - margin:
                    cv2.circle(img, (int(px), int(py)), 2, color, -1)

        # Main plane and secondary rectangles in front view.
        if not ylabel.startswith("depth"):
            rect = np.array(
                [[plane.u_min, plane.v_min], [plane.u_max, plane.v_min], [plane.u_max, plane.v_max], [plane.u_min, plane.v_max]]
            )
            cv2.polylines(img, [tr(rect[:, 0], rect[:, 1])], True, (0, 170, 50), 3, cv2.LINE_AA)
            for patch in patches:
                if patch.kind != "front":
                    continue
                rr = np.array(
                    [[patch.u_min, patch.v_min], [patch.u_max, patch.v_min], [patch.u_max, patch.v_max], [patch.u_min, patch.v_max]]
                )
                cv2.polylines(img, [tr(rr[:, 0], rr[:, 1])], True, (30, 120, 240), 3, cv2.LINE_AA)
        else:
            base = np.array([[plane.u_min, 0.0], [plane.u_max, 0.0]])
            cv2.line(img, tuple(tr(base[:, 0], base[:, 1])[0]), tuple(tr(base[:, 0], base[:, 1])[1]), (0, 170, 50), 3)
            for patch in patches:
                if patch.kind == "front":
                    p = tr(np.array([patch.u_min, patch.u_max]), np.array([patch.depth_m, patch.depth_m]))
                    cv2.line(img, tuple(p[0]), tuple(p[1]), (30, 120, 240), 3)

        cv2.putText(img, title, (24, 35), cv2.FONT_HERSHEY_SIMPLEX, 0.82, (20, 20, 20), 2, cv2.LINE_AA)
        cv2.putText(img, xlabel, (panel_w // 2 - 120, panel_h - 20), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (70, 70, 70), 1, cv2.LINE_AA)
        cv2.putText(img, ylabel, (18, panel_h // 2), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (70, 70, 70), 1, cv2.LINE_AA)
        return img

    sheet[:650, :900] = make_panel("Front view: secondary clusters on facade", u, v, "u facade horizontal (m)", "v vertical (m)")
    sheet[:650, 900:] = make_panel("Top view: extrusion depth", u, d, "u facade horizontal (m)", "depth from main plane (m)")

    info = np.full((650, 900, 3), 250, dtype=np.uint8)
    lines = [
        "PLANAR 3D GEOMETRY",
        f"Main plane: {plane.width_m():.2f} m x {plane.height_m():.2f} m",
        f"Secondary clusters: {len(clusters)}",
        f"Generated patches: {len(patches)}",
        "",
        "Green = main rigid facade plane",
        "Blue/orange = out-of-plane point clusters",
        "Blue rectangles = clean secondary front planes",
        "",
        "Interpretation:",
        "- noisy points are not the final geometry;",
        "- each cluster becomes a clean planar surface;",
        "- side planes make the model rotatable in 3D;",
        "- texture/ortho must be rendered per plane.",
    ]
    y0 = 45
    for i, line in enumerate(lines):
        scale = 0.82 if i == 0 else 0.58
        thick = 2 if i == 0 else 1
        cv2.putText(info, line, (32, y0), cv2.FONT_HERSHEY_SIMPLEX, scale, (20, 20, 20), thick, cv2.LINE_AA)
        y0 += 38 if i == 0 else 30

    table = np.full((650, 900, 3), 248, dtype=np.uint8)
    cv2.putText(table, "Detected secondary front planes", (24, 35), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (20, 20, 20), 2, cv2.LINE_AA)
    y = 80
    for patch in [p for p in patches if p.kind == "front"][:12]:
        text = f"{patch.name}: width {patch.width_m:.2f}m  height {patch.height_m:.2f}m  depth {patch.depth_m:.2f}m  pts {patch.point_count}"
        cv2.putText(table, text, (24, y), cv2.FONT_HERSHEY_SIMPLEX, 0.53, (40, 40, 40), 1, cv2.LINE_AA)
        y += 34

    sheet[650:, :900] = table
    sheet[650:, 900:] = info
    cv2.imwrite(str(out), sheet, [cv2.IMWRITE_JPEG_QUALITY, 92])


def draw_ortho_overlay(out: Path, ortho_path: Path, plane, patches: list[PlanePatch]) -> None:
    img = cv2.imread(str(ortho_path))
    if img is None:
        return
    h, w = img.shape[:2]

    def xy(u_coord: float, v_coord: float) -> tuple[int, int]:
        x = int(round((u_coord - plane.u_min) / max(plane.u_max - plane.u_min, 1e-9) * w))
        y = int(round((plane.v_max - v_coord) / max(plane.v_max - plane.v_min, 1e-9) * h))
        return x, y

    colors = [(0, 210, 255), (60, 220, 80), (255, 120, 60), (255, 80, 210), (40, 190, 210)]
    front_patches = [p for p in patches if p.kind == "front"]
    for i, patch in enumerate(front_patches):
        color = colors[i % len(colors)]
        x0, y1 = xy(patch.u_min, patch.v_min)
        x1, y0 = xy(patch.u_max, patch.v_max)
        cv2.rectangle(img, (x0, y0), (x1, y1), color, 7, cv2.LINE_AA)
        label = f"{patch.name} d={patch.depth_m:.2f}m"
        cv2.putText(
            img,
            label,
            (x0 + 8, max(38, y0 - 10)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.85,
            color,
            3,
            cv2.LINE_AA,
        )

    cv2.imwrite(str(out), img, [cv2.IMWRITE_JPEG_QUALITY, 92])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("session", nargs="?", default="/Users/liscio/Acrobatica/backend/data/fixtures/53f1b49d")
    parser.add_argument("--cloud", type=Path, default=Path("/tmp/sparse_53f1b49d/cloud.ply"))
    parser.add_argument("--out-dir", type=Path, default=Path("/tmp/sparse_53f1b49d/planar_geometry"))
    parser.add_argument("--main-dist", type=float, default=0.12)
    parser.add_argument("--depth-threshold", type=float, default=0.55)
    parser.add_argument("--cell-m", type=float, default=0.18)
    parser.add_argument("--min-points", type=int, default=120)
    parser.add_argument("--min-size-m", type=float, default=0.65)
    parser.add_argument("--pad-m", type=float, default=0.18)
    parser.add_argument("--close-iterations", type=int, default=1)
    parser.add_argument("--dilate-iterations", type=int, default=0)
    parser.add_argument("--split-gap-m", type=float, default=0.85)
    parser.add_argument("--ortho", type=Path, default=Path("/tmp/sparse_53f1b49d/facade_flat_rigid_ortho.png"))
    args = parser.parse_args()

    src = SessionSource.open(args.session)
    plane = estimate_plane(src, args.cloud, dist=args.main_dist, pad=0.35)
    pts = load_ply(args.cloud)
    point = np.asarray(plane.point)
    right = np.asarray(plane.right)
    up = np.asarray(plane.up)
    normal = np.asarray(plane.normal)
    rel = pts - point
    u = rel @ right
    v = rel @ up
    d = rel @ normal

    clusters = _component_clusters(
        u,
        v,
        d,
        u_min=plane.u_min,
        u_max=plane.u_max,
        v_min=plane.v_min,
        v_max=plane.v_max,
        depth_threshold=args.depth_threshold,
        cell_m=args.cell_m,
        min_points=args.min_points,
        close_iterations=args.close_iterations,
        dilate_iterations=args.dilate_iterations,
        split_gap_m=args.split_gap_m,
    )

    patches: list[PlanePatch] = []
    for i, idx in enumerate(clusters, start=1):
        patches.extend(
            _make_extrusion_patches(
                i,
                idx,
                point,
                right,
                up,
                normal,
                u,
                v,
                d,
                min_size_m=args.min_size_m,
                pad_m=args.pad_m,
            )
        )

    main_origin = _world(point, right, up, normal, plane.u_min, plane.v_min, 0.0)
    main_patch = PlanePatch(
        name="main_facade",
        kind="main",
        origin=tuple(main_origin.tolist()),
        right=tuple(right.tolist()),
        up=tuple(up.tolist()),
        normal=tuple(normal.tolist()),
        width_m=plane.width_m(),
        height_m=plane.height_m(),
        depth_m=0.0,
        u_min=plane.u_min,
        u_max=plane.u_max,
        v_min=plane.v_min,
        v_max=plane.v_max,
        point_count=int(len(pts)),
    )

    args.out_dir.mkdir(parents=True, exist_ok=True)
    obj_path = args.out_dir / "facade_planar_geometry.obj"
    json_path = args.out_dir / "facade_planar_geometry.json"
    report_path = args.out_dir / "facade_planar_geometry_report.jpg"
    overlay_path = args.out_dir / "facade_planar_geometry_overlay.jpg"
    write_obj(obj_path, main_patch, patches)
    json_path.write_text(
        json.dumps(
            {
                "main": asdict(main_patch),
                "patches": [asdict(p) for p in patches],
                "cluster_count": len(clusters),
                "depth_threshold": args.depth_threshold,
                "cell_m": args.cell_m,
                "close_iterations": args.close_iterations,
                "dilate_iterations": args.dilate_iterations,
                "split_gap_m": args.split_gap_m,
            },
            indent=2,
        )
    )
    draw_report(report_path, plane, patches, u, v, d, clusters)
    draw_ortho_overlay(overlay_path, args.ortho, plane, patches)

    print(f"clusters: {len(clusters)}")
    print(f"patches: {len(patches)}")
    print(f"obj: {obj_path}")
    print(f"json: {json_path}")
    print(f"report: {report_path}")
    if overlay_path.exists():
        print(f"overlay: {overlay_path}")
    for p in patches:
        if p.kind == "front":
            print(f"{p.name}: {p.width_m:.2f}m x {p.height_m:.2f}m depth={p.depth_m:.2f}m pts={p.point_count}")


if __name__ == "__main__":
    main()
