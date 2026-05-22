"""Test triangolazione 3D (port da packages/shared/src/photogrammetry/triangulate.test.ts)."""
from __future__ import annotations
import math

import pytest

from app.services.triangulation_service import (
    CameraPose,
    Point3D,
    Ray3D,
    polygon_area_3d,
    quad_dimensions,
    ray_from_pixel,
    triangulate_rays,
    widest_baseline_pair,
)


def _pose_at(x: float, y: float = 0, z: float = 0, fx: float = 1500, w: int = 1920, h: int = 1440) -> CameraPose:
    """Camera che guarda verso -Z dal punto (x, y, z)."""
    return CameraPose(
        transform=(
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, z, 1,
        ),
        intrinsics=(fx, 0, 0, 0, fx, 0, w / 2, h / 2, 1),
    )


def test_ray_at_principal_point_goes_along_minus_z():
    p = _pose_at(0, 0, 0)
    r = ray_from_pixel(p, 1920 / 2, 1440 / 2)
    assert r.origin == Point3D(0, 0, 0)
    assert abs(r.direction.x) < 1e-6
    assert abs(r.direction.y) < 1e-6
    assert r.direction.z == pytest.approx(-1, abs=1e-6)


def test_ray_right_of_centre_bends_positive_x():
    p = _pose_at(0, 0, 0)
    r = ray_from_pixel(p, 1920 / 2 + 300, 1440 / 2)
    assert r.direction.x > 0
    assert r.direction.z < 0


def test_triangulate_two_rays_recovers_3d_point():
    target = Point3D(1.0, 2.0, -5.0)
    pa = _pose_at(0, 0, 0)
    pb = _pose_at(3, 0, 0)

    def project(pose: CameraPose) -> tuple[float, float]:
        tx, ty, tz = pose.transform[12], pose.transform[13], pose.transform[14]
        dx, dy, dz = target.x - tx, target.y - ty, target.z - tz
        fx, fy = pose.intrinsics[0], pose.intrinsics[4]
        cx, cy = pose.intrinsics[6], pose.intrinsics[7]
        u = cx + fx * (dx / -dz)
        v = cy - fy * (dy / -dz)
        return u, v

    ua, va = project(pa)
    ub, vb = project(pb)
    rays = [ray_from_pixel(pa, ua, va), ray_from_pixel(pb, ub, vb)]
    res = triangulate_rays(rays)
    assert res is not None
    assert res.x == pytest.approx(target.x, abs=1e-3)
    assert res.y == pytest.approx(target.y, abs=1e-3)
    assert res.z == pytest.approx(target.z, abs=1e-3)


def test_triangulate_fewer_than_two_rays_returns_none():
    r = Ray3D(Point3D(0, 0, 0), Point3D(0, 0, -1))
    assert triangulate_rays([]) is None
    assert triangulate_rays([r]) is None


def test_widest_baseline_pair_picks_furthest():
    poses = [_pose_at(0), _pose_at(0.5), _pose_at(5)]
    pair = widest_baseline_pair(poses)
    assert pair == (0, 2)


def test_quad_dimensions_and_area():
    # Quadrato verticale 5×3 sul piano XY
    quad = [
        Point3D(0, 3, 0),
        Point3D(5, 3, 0),
        Point3D(5, 0, 0),
        Point3D(0, 0, 0),
    ]
    w, h = quad_dimensions(quad)
    assert w == pytest.approx(5, abs=1e-6)
    assert h == pytest.approx(3, abs=1e-6)
    assert polygon_area_3d(quad) == pytest.approx(15, abs=1e-6)
