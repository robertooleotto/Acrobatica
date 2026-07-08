#!/usr/bin/env python3
"""Detector piani v2 — Open3D `detect_planar_patches` (Araújo & Oliveira 2020).

Trova le facce della mesh A PRESCINDERE dall'orientamento (verticali, oblique,
trapezoidali): niente assi imposti. Pipeline:

  1. patch planari robuste dalla nuvola dei vertici (qualsiasi normale);
  2. fusione delle ipotesi complanari (stessa normale, offset vicino);
  3. assegnazione ESCLUSIVA dei triangoli al piano migliore (distanza+allineamento);
  4. refit del piano dai suoi triangoli (centroide pesato area + SVD);
  5. contorno = guscio convesso semplificato nel piano → POLIGONO VERO (trapezi ok);
  6. filtri (area minima relativa) e classificazione facciata/spalla/falda.

La gravità (--up) serve SOLO a orientare gli assi u/v dentro al piano e a
scartare i piani orizzontali (terreno/tetti piani), MAI a raddrizzare i muri.

Uso:
  python -m scripts.detect_planes_open3d mesh.obj --out /tmp/piani_v2 [--up 0 1 0]
      [--include-horizontal] [--min-area-frac 0.04]

Output: <out>.json con {up, planes:[{nome,tipo,punto,normale,corners,area_m2,w,h,
triangoli}]} — corners è un poligono di N vertici (non solo 4).
"""
import argparse
import json
import math
import sys

import numpy as np

sys.path.insert(0, ".")
from app.services.ortho_bake import load_obj


def _unit(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def convex_hull_2d(pts):
    """Guscio convesso (monotone chain), pts (N,2) → vertici CCW."""
    P = sorted(set(map(tuple, np.round(pts, 5))))
    if len(P) < 3:
        return np.asarray(P)
    def cross(o, a, b):
        return (a[0]-o[0])*(b[1]-o[1]) - (a[1]-o[1])*(b[0]-o[0])
    lo, up = [], []
    for p in P:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(P):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0:
            up.pop()
        up.append(p)
    return np.asarray(lo[:-1] + up[:-1])


def simplify_polygon(poly, ang_deg=8.0, min_edge=0.05):
    """Rimuove i vertici quasi-collineari (svolta < ang_deg) e i lati corti."""
    if len(poly) <= 4:
        return poly
    keep = []
    n = len(poly)
    for i in range(n):
        a, b, c = poly[(i-1) % n], poly[i], poly[(i+1) % n]
        e1, e2 = _unit(b - a), _unit(c - b)
        ang = math.degrees(math.acos(np.clip(e1 @ e2, -1, 1)))
        if ang > ang_deg and np.linalg.norm(b - a) > min_edge:
            keep.append(b)
    return np.asarray(keep) if len(keep) >= 3 else poly


def poly_area(poly):
    x, y = poly[:, 0], poly[:, 1]
    return 0.5 * abs(np.dot(x, np.roll(y, 1)) - np.dot(y, np.roll(x, 1)))


def detect(V, F, up, include_horizontal=False, min_area_frac=0.04,
           horiz_dot=0.85, log=print):
    import open3d as o3d
    diag = float(np.linalg.norm(V.max(0) - V.min(0)))

    mesh = o3d.geometry.TriangleMesh(o3d.utility.Vector3dVector(V),
                                     o3d.utility.Vector3iVector(F))
    mesh.compute_vertex_normals()
    pcd = o3d.geometry.PointCloud()
    pcd.points = mesh.vertices
    pcd.normals = mesh.vertex_normals

    # 1) ipotesi di piano: patch robuste, QUALSIASI orientamento.
    #    Parametri DEFAULT: i custom severi mancavano piani su mesh rade/sintetiche.
    patches = pcd.detect_planar_patches()
    log(f"  patch grezze: {len(patches)}")
    hyps = []
    for obb in patches:
        n = _unit(np.asarray(obb.R)[:, 2])
        c = np.asarray(obb.center)
        hyps.append({"n": n, "c": c, "off": float(c @ n)})

    # 2) fusione ipotesi complanari: stessa normale (entro 12°) e distanza
    #    piano-piano piccola → un'ipotesi sola (media). Itera finché stabile.
    cos_t, off_t = math.cos(math.radians(12)), diag * 0.04
    merged = [dict(h) for h in hyps]
    stable = False
    while not stable:
        stable = True
        out = []
        for h in merged:
            hit = None
            for m in out:
                if abs(float(h["n"] @ m["n"])) > cos_t and \
                   abs(float((h["c"] - m["c"]) @ m["n"])) < off_t:
                    hit = m
                    break
            if hit is None:
                out.append(h)
            else:
                # media semplice di centro e normale (segno coerente)
                n2 = h["n"] if float(h["n"] @ hit["n"]) >= 0 else -h["n"]
                hit["n"] = _unit(hit["n"] + n2)
                hit["c"] = (hit["c"] + h["c"]) / 2
                stable = False
        merged = out
    log(f"  ipotesi dopo fusione: {len(merged)}")

    # triangoli: centroidi, normali, aree
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    cr = np.cross(b - a, c - a)
    tarea = 0.5 * np.linalg.norm(cr, axis=1)
    tn = cr / np.maximum(2 * tarea, 1e-12)[:, None]
    tc = (a + b + c) / 3.0

    # 3) assegnazione esclusiva al piano migliore
    tol = diag * 0.01
    cos_assign = math.cos(math.radians(35))
    best_d = np.full(len(F), np.inf)
    best_p = np.full(len(F), -1, np.int32)
    for pi, m in enumerate(merged):
        d = np.abs((tc - m["c"]) @ m["n"])
        ok = (d < tol) & (np.abs(tn @ m["n"]) > cos_assign) & (d < best_d)
        best_d[ok] = d[ok]
        best_p[ok] = pi

    up = _unit(np.asarray(up, float))

    def build_plane(tri):
        """Refit (centroide pesato + SVD) e poligono convesso dai triangoli."""
        if len(tri) < 30:
            return None
        w = tarea[tri][:, None]
        ctr = (tc[tri] * w).sum(0) / w.sum()
        vid = np.unique(F[tri].reshape(-1))
        P = V[vid]
        _, _, vt = np.linalg.svd(P - ctr, full_matrices=False)
        n = _unit(vt[-1])
        # verso fuori dal muro = maggioranza pesata delle normali mesh
        if float(((tn[tri] @ n) * tarea[tri]).sum()) < 0:
            n = -n
        # 5) assi nel piano (v = gravità proiettata) e poligono convesso
        v = up - (up @ n) * n
        v = _unit(v) if np.linalg.norm(v) > 1e-4 else _unit(np.cross(n, [1, 0, 0]))
        u = _unit(np.cross(v, n))
        uv = np.stack([(P - ctr) @ u, (P - ctr) @ v], 1)
        hull = convex_hull_2d(uv)
        if len(hull) < 3:
            return None
        hull = simplify_polygon(hull, ang_deg=12.0, min_edge=diag * 0.015)
        area = float(poly_area(hull))
        corners = [(ctr + u * x + v * y).tolist() for x, y in hull]
        return {"n": n, "ctr": ctr, "tilt": abs(float(n @ up)), "area": area,
                "w": float(hull[:, 0].max() - hull[:, 0].min()),
                "h": float(hull[:, 1].max() - hull[:, 1].min()),
                "corners": corners, "tri": np.asarray(tri)}

    planes = []
    for pi in range(len(merged)):
        p = build_plane(np.where(best_p == pi)[0])
        if p is not None:
            planes.append(p)

    # 4b) fusione POST-refit: stesso muro spezzato dal rilievo (bugnato/cornici)
    #     → normali vicine (≤18°) e distanza piano-piano piccola ai due centroidi.
    cos_pm, d_pm = math.cos(math.radians(18)), diag * 0.03
    changed = True
    while changed:
        changed = False
        for i in range(len(planes)):
            for j in range(i + 1, len(planes)):
                a, b2 = planes[i], planes[j]
                if float(a["n"] @ b2["n"]) > cos_pm and \
                   abs(float((a["ctr"] - b2["ctr"]) @ b2["n"])) < d_pm and \
                   abs(float((b2["ctr"] - a["ctr"]) @ a["n"])) < d_pm:
                    m2 = build_plane(np.concatenate([a["tri"], b2["tri"]]))
                    if m2 is not None:
                        planes[i] = m2
                        planes.pop(j)
                        changed = True
                        break
            if changed:
                break
    log(f"  piani dopo fusione post-refit: {len(planes)}")

    # scarta orizzontali (terreno/tetti piani) se non richiesti
    planes = [p for p in planes if include_horizontal or p["tilt"] <= horiz_dot]
    for p in planes:
        p["tri"] = p["tri"].tolist()

    # 6) filtro area relativa + classificazione
    if not planes:
        return []
    amax = max(p["area"] for p in planes)
    planes = [p for p in planes if p["area"] >= min_area_frac * amax]
    planes.sort(key=lambda p: -p["area"])
    n_main = planes[0]["n"]
    out = []
    for i, p in enumerate(planes, 1):
        if p["tilt"] > 0.30:
            tipo = "falda"                              # obliquo (timpano/scarpa)
        elif abs(float(p["n"] @ n_main)) > 0.5:
            tipo = "facciata"
        else:
            tipo = "spalla"
        nome = {"facciata": "Facciata", "spalla": "Spalletta", "falda": "Falda"}[tipo]
        out.append({"nome": f"{nome} {i}", "tipo": tipo,
                    "punto": p["ctr"].tolist(), "normale": p["n"].tolist(),
                    "corners": p["corners"], "area_m2": round(p["area"], 2),
                    "w": round(p["w"], 3), "h": round(p["h"], 3),
                    "triangoli": p["tri"]})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("obj")
    ap.add_argument("--out", default="/tmp/piani_v2")
    ap.add_argument("--up", type=float, nargs=3, default=[0.0, 1.0, 0.0])
    ap.add_argument("--include-horizontal", action="store_true")
    ap.add_argument("--min-area-frac", type=float, default=0.04)
    args = ap.parse_args()

    V, F = load_obj(args.obj)
    print(f"mesh: {len(V)} vertici, {len(F)} triangoli")
    planes = detect(V, F, args.up, args.include_horizontal, args.min_area_frac)
    print(f"\nPIANI TROVATI: {len(planes)}")
    for p in planes:
        n = p["normale"]
        print(f"  {p['nome']:14s} {p['tipo']:9s} {p['w']:.2f}x{p['h']:.2f}  "
              f"area={p['area_m2']:6.2f}  n=[{n[0]:+.2f},{n[1]:+.2f},{n[2]:+.2f}]  "
              f"vertici_poligono={len(p['corners'])}  tri={len(p['triangoli'])}")
    with open(args.out + ".json", "w") as fh:
        json.dump({"up": list(args.up), "planes": planes}, fh)
    print(f"\nscritto: {args.out}.json")


if __name__ == "__main__":
    main()
