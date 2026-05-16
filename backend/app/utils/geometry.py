"""Helper geometrici 2D (ordinamento quad, area via shoelace, ecc.)."""
from __future__ import annotations
import math


Pt = tuple[float, float]


def polygon_area_pixels(polygon: list[Pt]) -> float:
    """Area di un poligono semplice via formula del laccio (Gauss)."""
    n = len(polygon)
    if n < 3:
        return 0.0
    s = 0.0
    for i in range(n):
        x1, y1 = polygon[i]
        x2, y2 = polygon[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return abs(s) * 0.5


def sort_quad_clockwise(quad: list[Pt]) -> list[Pt]:
    """Ordina 4 punti in TL, TR, BR, BL secondo la convenzione immagine (y verso il basso)."""
    if len(quad) != 4:
        raise ValueError("Servono esattamente 4 punti")
    cx = sum(p[0] for p in quad) / 4
    cy = sum(p[1] for p in quad) / 4
    def angle(p: Pt) -> float:
        return math.atan2(p[1] - cy, p[0] - cx)
    sorted_pts = sorted(quad, key=angle)
    # Trova quello in alto-sinistra (minor x+y) e inizia da lì in senso orario.
    start = min(range(4), key=lambda i: sorted_pts[i][0] + sorted_pts[i][1])
    rotated = sorted_pts[start:] + sorted_pts[:start]
    return rotated
