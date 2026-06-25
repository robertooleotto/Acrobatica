#!/usr/bin/env python3
"""Render a rigid flat facade orthophoto from original ARKit photos.

This deliberately does *not* render ODM's textured mesh. The facade is modeled
as a single vertical plane; every output pixel lies on that plane, so windows and
storeys cannot bend with mesh noise. ODM / sparse reconstruction is used only to
estimate plane bounds.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import cv2
import numpy as np
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
load_dotenv(ROOT / ".env")

from _session_source import SessionSource
from app.services.orthorectify_service import WallPlane


def load_ply(path: Path) -> np.ndarray:
    pts: list[tuple[float, float, float]] = []
    with path.open() as fh:
        started = False
        for line in fh:
            if started:
                vals = line.split()
                if len(vals) >= 3:
                    pts.append((float(vals[0]), float(vals[1]), float(vals[2])))
            elif line.startswith("end_header"):
                started = True
    return np.asarray(pts, dtype=np.float64)


def ransac_plane(pts: np.ndarray, dist_thresh: float, iters: int = 2000) -> np.ndarray:
    rng = np.random.default_rng(3)
    best: np.ndarray | None = None
    for _ in range(iters):
        sample = pts[rng.choice(len(pts), 3, replace=False)]
        normal = np.cross(sample[1] - sample[0], sample[2] - sample[0])
        norm = np.linalg.norm(normal)
        if norm < 1e-9:
            continue
        normal /= norm
        d = -float(normal @ sample[0])
        inliers = np.abs(pts @ normal + d) < dist_thresh
        if best is None or inliers.sum() > best.sum():
            best = inliers
    if best is None:
        raise RuntimeError("RANSAC plane failed")
    return best


def estimate_plane(src: SessionSource, cloud_path: Path, dist: float, pad: float) -> WallPlane:
    pts = load_ply(cloud_path)
    inliers = ransac_plane(pts, dist_thresh=dist)
    facade_pts = pts[inliers]

    opticals = []
    for photo in src.photos:
        T = np.asarray(photo["metadata"]["camera_transform"], dtype=np.float64).reshape(
            4, 4, order="F"
        )
        optical = -(T[:3, :3] @ np.array([0.0, 0.0, 1.0]))
        optical[1] = 0.0
        norm = np.linalg.norm(optical)
        if norm > 1e-6:
            opticals.append(optical / norm)
    mean_opt = np.mean(opticals, axis=0)
    mean_opt /= np.linalg.norm(mean_opt)
    normal = -mean_opt
    normal /= np.linalg.norm(normal)

    up = np.array([0.0, 1.0, 0.0])
    right = np.cross(up, normal)
    right /= np.linalg.norm(right)
    centroid = facade_pts.mean(axis=0)
    us = (facade_pts - centroid) @ right
    vs = (facade_pts - centroid) @ up
    u_min, u_max = np.percentile(us, [1.0, 99.0])
    v_min, v_max = np.percentile(vs, [1.0, 99.0])
    return WallPlane(
        point=tuple(float(x) for x in centroid),
        normal=tuple(float(x) for x in normal),
        right=tuple(float(x) for x in right),
        up=tuple(float(x) for x in up),
        u_min=float(u_min) - pad,
        u_max=float(u_max) + pad,
        v_min=float(v_min) - pad,
        v_max=float(v_max) + pad,
    )


def landscape_aligned(img: np.ndarray, meta: dict) -> np.ndarray:
    h, w = img.shape[:2]
    mw, mh = int(meta["image_width"]), int(meta["image_height"])
    if (w, h) != (mw, mh) and (h, w) == (mw, mh):
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    return img


def project_grid_to_photo(
    grid_world: np.ndarray,
    meta: dict,
    image_shape: tuple[int, int],
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    h, w = image_shape
    T = np.asarray(meta["camera_transform"], dtype=np.float64).reshape(4, 4, order="F")
    R = T[:3, :3]
    cam = T[:3, 3]
    K = meta["camera_intrinsics"]
    fx, fy, cx, cy = float(K[0]), float(K[4]), float(K[6]), float(K[7])

    rel = grid_world - cam
    cam_xyz = rel @ R
    z = cam_xyz[..., 2]
    px = -fx * cam_xyz[..., 0] / z + cx
    py = fy * cam_xyz[..., 1] / z + cy
    valid = (z < -1e-4) & (px >= 1) & (py >= 1) & (px < w - 2) & (py < h - 2)
    return px.astype(np.float32), py.astype(np.float32), valid, z


def render_flat(src: SessionSource, plane: WallPlane, out_path: Path, ppm: float) -> dict:
    width = int(math.ceil(plane.width_m() * ppm))
    height = int(math.ceil(plane.height_m() * ppm))
    width = max(64, min(width, 9000))
    height = max(64, min(height, 9000))
    ppm_x = width / plane.width_m()
    ppm_y = height / plane.height_m()

    xs = plane.u_min + (np.arange(width, dtype=np.float64) + 0.5) / ppm_x
    ys = plane.v_max - (np.arange(height, dtype=np.float64) + 0.5) / ppm_y
    uu, vv = np.meshgrid(xs, ys)

    point = np.asarray(plane.point, dtype=np.float64)
    right = np.asarray(plane.right, dtype=np.float64)
    up = np.asarray(plane.up, dtype=np.float64)
    normal = np.asarray(plane.normal, dtype=np.float64)
    grid_world = point + uu[..., None] * right + vv[..., None] * up

    best_score = np.full((height, width), -np.inf, dtype=np.float32)
    best_img = np.zeros((height, width, 3), dtype=np.uint8)
    source = np.full((height, width), -1, dtype=np.int16)

    included = 0
    photos = sorted(src.photos, key=lambda p: int(p["order_index"]))
    for photo in photos:
        order = int(photo["order_index"])
        meta = photo["metadata"]
        img = src.load_image(photo)
        if img is None:
            continue
        img = landscape_aligned(img, meta)
        ih, iw = img.shape[:2]
        map_x, map_y, valid, z = project_grid_to_photo(grid_world, meta, (ih, iw))

        T = np.asarray(meta["camera_transform"], dtype=np.float64).reshape(4, 4, order="F")
        optical = -(T[:3, :3] @ np.array([0.0, 0.0, 1.0]))
        cosang = float(np.dot(optical, -normal) / max(np.linalg.norm(optical), 1e-9))
        if cosang < 0.2:
            continue

        # Prefer central pixels, more frontal shots, and closer source images.
        nx = (map_x - iw * 0.5) / (iw * 0.5)
        ny = (map_y - ih * 0.5) / (ih * 0.5)
        centrality = 1.0 - np.clip(np.sqrt(nx * nx + ny * ny), 0.0, 1.4) / 1.4
        distance_score = 1.0 / np.maximum(np.abs(z), 0.5)
        score = (2.0 * centrality + 1.2 * cosang + 0.35 * distance_score).astype(np.float32)
        score[~valid] = -np.inf

        update = score > best_score
        if not np.any(update):
            continue
        sampled = cv2.remap(
            img,
            map_x,
            map_y,
            interpolation=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=(0, 0, 0),
        )
        best_img[update] = sampled[update]
        best_score[update] = score[update]
        source[update] = order
        included += 1

    coverage = source >= 0
    if np.any(~coverage):
        mask = (~coverage).astype(np.uint8) * 255
        best_img = cv2.inpaint(best_img, mask, 3, cv2.INPAINT_TELEA)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out_path), best_img, [cv2.IMWRITE_PNG_COMPRESSION, 3])

    source_path = out_path.with_name(out_path.stem + "_source.png")
    source_vis = np.zeros((height, width, 3), dtype=np.uint8)
    rng = np.random.default_rng(10)
    for order in np.unique(source[source >= 0]):
        color = rng.integers(40, 230, size=3, dtype=np.uint8)
        source_vis[source == order] = color
    cv2.imwrite(str(source_path), source_vis)

    return {
        "output": str(out_path),
        "source_map": str(source_path),
        "size": [width, height],
        "included_photos": included,
        "coverage_pct": float(coverage.mean() * 100.0),
        "plane": plane.to_dict(),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("session", nargs="?", default="/Users/liscio/Acrobatica/backend/data/fixtures/53f1b49d")
    parser.add_argument("--cloud", type=Path, default=Path("/tmp/sparse_53f1b49d/cloud.ply"))
    parser.add_argument("--dist", type=float, default=0.12)
    parser.add_argument("--pad", type=float, default=0.35)
    parser.add_argument("--ppm", type=float, default=110.0)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("/tmp/sparse_53f1b49d/facade_flat_rigid_ortho.png"),
    )
    args = parser.parse_args()

    src = SessionSource.open(args.session)
    plane = estimate_plane(src, args.cloud, dist=args.dist, pad=args.pad)
    stats = render_flat(src, plane, args.out, ppm=args.ppm)
    for key, value in stats.items():
        if key != "plane":
            print(f"{key}: {value}")
    print(f"plane width_m={plane.width_m():.2f} height_m={plane.height_m():.2f}")


if __name__ == "__main__":
    main()
