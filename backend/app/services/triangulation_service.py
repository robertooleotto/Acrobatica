"""Triangolazione multi-view dei 4 angoli della facciata.

Per ogni angolo, l'utente tappa su 2+ foto della sessione (in pixel della foto
raw, sistema landscape ARKit). Il backend:
  1. Per ogni tap, calcola il raggio 3D world-space dato pose+intrinsics della foto.
  2. Triangola i raggi (least squares 3x3) → punto 3D.
  3. Da 4 punti 3D calcola larghezza/altezza/area come fa scan3d.ts (Strada A).

Port diretto della logica TS in `packages/shared/src/photogrammetry/triangulate.ts`
e `packages/shared/src/facade/scan3d.ts` della vecchia Strada A.
"""
from __future__ import annotations
import math
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Point3D:
    x: float
    y: float
    z: float


@dataclass(frozen=True)
class Ray3D:
    origin: Point3D
    direction: Point3D  # unit vector


@dataclass(frozen=True)
class CameraPose:
    """ARKit camera→world transform (16 floats col-major) + 3x3 intrinsics (9 col-major)."""
    transform: tuple[float, ...]   # 16
    intrinsics: tuple[float, ...]  # 9


def ray_from_pixel(pose: CameraPose, px: float, py: float) -> Ray3D:
    """Raggio world-space che esce dall'origine della camera attraverso (px, py).

    Pixel in coordinate ARKit raw (origine top-left, +x destra, +y giù).
    ARKit camera frame: +x destra, +y su, +z verso il viewer; guarda lungo -z.
    """
    K = pose.intrinsics
    fx, fy, cx, cy = K[0], K[4], K[6], K[7]
    dx_cam = (px - cx) / fx
    dy_cam = -(py - cy) / fy
    dz_cam = -1.0
    n = math.sqrt(dx_cam * dx_cam + dy_cam * dy_cam + dz_cam * dz_cam)
    dx, dy, dz = dx_cam / n, dy_cam / n, dz_cam / n

    T = pose.transform  # col-major 4x4: col0 (x axis world), col1 (y), col2 (z), col3 (translation)
    wx = T[0] * dx + T[4] * dy + T[8] * dz
    wy = T[1] * dx + T[5] * dy + T[9] * dz
    wz = T[2] * dx + T[6] * dy + T[10] * dz
    return Ray3D(
        origin=Point3D(T[12], T[13], T[14]),
        direction=Point3D(wx, wy, wz),
    )


def triangulate_rays(rays: list[Ray3D]) -> Optional[Point3D]:
    """Minimi quadrati: X = argmin Σ ||(I - d_i d_iᵀ)(X - o_i)||²."""
    if len(rays) < 2:
        return None
    a00 = a01 = a02 = a11 = a12 = a22 = 0.0
    b0 = b1 = b2 = 0.0
    for r in rays:
        dx, dy, dz = r.direction.x, r.direction.y, r.direction.z
        ox, oy, oz = r.origin.x, r.origin.y, r.origin.z
        m00 = 1 - dx * dx
        m01 = -dx * dy
        m02 = -dx * dz
        m11 = 1 - dy * dy
        m12 = -dy * dz
        m22 = 1 - dz * dz
        a00 += m00; a01 += m01; a02 += m02
        a11 += m11; a12 += m12
        a22 += m22
        b0 += m00 * ox + m01 * oy + m02 * oz
        b1 += m01 * ox + m11 * oy + m12 * oz
        b2 += m02 * ox + m12 * oy + m22 * oz
    return _solve3x3(
        [[a00, a01, a02], [a01, a11, a12], [a02, a12, a22]],
        [b0, b1, b2],
    )


def _solve3x3(A: list[list[float]], b: list[float]) -> Optional[Point3D]:
    a = [row[:] for row in A]
    c = b[:]
    for i in range(3):
        # pivot
        max_v = abs(a[i][i])
        max_row = i
        for k in range(i + 1, 3):
            if abs(a[k][i]) > max_v:
                max_v, max_row = abs(a[k][i]), k
        if max_v < 1e-9:
            return None
        if max_row != i:
            a[i], a[max_row] = a[max_row], a[i]
            c[i], c[max_row] = c[max_row], c[i]
        for k in range(i + 1, 3):
            f = a[k][i] / a[i][i]
            for j in range(i, 3):
                a[k][j] -= f * a[i][j]
            c[k] -= f * c[i]
    x = [0.0, 0.0, 0.0]
    for i in (2, 1, 0):
        s = c[i]
        for j in range(i + 1, 3):
            s -= a[i][j] * x[j]
        x[i] = s / a[i][i]
    return Point3D(x[0], x[1], x[2])


def widest_baseline_pair(poses: list[CameraPose]) -> Optional[tuple[int, int]]:
    if len(poses) < 2:
        return None
    best, bi, bj = -1.0, 0, 1
    for i in range(len(poses)):
        Ti = poses[i].transform
        for j in range(i + 1, len(poses)):
            Tj = poses[j].transform
            dx = Ti[12] - Tj[12]
            dy = Ti[13] - Tj[13]
            dz = Ti[14] - Tj[14]
            d2 = dx * dx + dy * dy + dz * dz
            if d2 > best:
                best, bi, bj = d2, i, j
    return (bi, bj)


# --- Quad dimensioni e area (port da facade/scan3d.ts) -----------------------

def _dist(p: Point3D, q: Point3D) -> float:
    return math.sqrt((p.x - q.x) ** 2 + (p.y - q.y) ** 2 + (p.z - q.z) ** 2)


def quad_dimensions(quad: list[Point3D]) -> tuple[float, float]:
    """Larghezza/altezza media di un quad TL, TR, BR, BL."""
    top = _dist(quad[0], quad[1])
    bottom = _dist(quad[3], quad[2])
    left = _dist(quad[0], quad[3])
    right = _dist(quad[1], quad[2])
    return ((top + bottom) / 2, (left + right) / 2)


def polygon_area_3d(polygon: list[Point3D]) -> float:
    """Area di un poligono 3D non-planare via somma dei cross-products triangolari."""
    if len(polygon) < 3:
        return 0.0
    o = polygon[0]
    tx = ty = tz = 0.0
    for i in range(1, len(polygon) - 1):
        ax, ay, az = polygon[i].x - o.x, polygon[i].y - o.y, polygon[i].z - o.z
        bx, by, bz = polygon[i + 1].x - o.x, polygon[i + 1].y - o.y, polygon[i + 1].z - o.z
        cx = ay * bz - az * by
        cy = az * bx - ax * bz
        cz = ax * by - ay * bx
        tx += cx; ty += cy; tz += cz
    return math.sqrt(tx * tx + ty * ty + tz * tz) / 2.0
