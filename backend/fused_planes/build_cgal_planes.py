#!/usr/bin/env python3
"""(b) Genera planes.json (piani candidati CGAL, in unità OC) dalla mesh OC.
Gira il binario Region-Growing (tools/cgal_regiongrow/rg) sulla mesh, fonde le
regioni coplanari e costruisce per ogni piano: normale, punto, corners (guscio
convesso). È l'input 'planes' della pipeline slice-contours->fused.

Uso:  python build_cgal_planes.py mesh_oc.obj out_planes.json
        [--rg <binario>] [--maxd 0.06] [--maxa 25] [--minr 25]
        [--min-area 0.05] [--cop-ang 8] [--cop-off 0.08]
"""
import argparse
import json
import math
import os
import subprocess
import tempfile
from collections import defaultdict

import numpy as np
RG_DEFAULT = os.environ.get("ACRO_REGIONGROW_BIN", "/usr/local/bin/acro-regiongrow")


def estimate_mesh_resolution(path, max_faces=50000):
    """Median triangle-edge length, in the mesh's own units."""
    vertices = []
    lengths = []
    with open(path) as source:
        for line in source:
            if line.startswith("v "):
                vertices.append([float(value) for value in line.split()[1:4]])
            elif line.startswith("f ") and len(lengths) < max_faces * 3:
                indices = [int(token.split("/")[0]) - 1 for token in line.split()[1:4]]
                if len(indices) < 3 or max(indices) >= len(vertices):
                    continue
                points = [np.asarray(vertices[index], dtype=float) for index in indices]
                lengths.extend((
                    float(np.linalg.norm(points[1] - points[0])),
                    float(np.linalg.norm(points[2] - points[1])),
                    float(np.linalg.norm(points[0] - points[2])),
                ))
    if not lengths:
        raise ValueError("mesh senza triangoli utili per stimare la risoluzione")
    return float(np.median(np.asarray(lengths, dtype=float)))


def convex_hull_indices(points):
    """Return the 2D monotone-chain hull indices without requiring SciPy."""
    ordered = sorted((float(p[0]), float(p[1]), i) for i, p in enumerate(points))
    if len(ordered) < 3:
        return [item[2] for item in ordered]

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower = []
    for item in ordered:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], item) <= 0:
            lower.pop()
        lower.append(item)
    upper = []
    for item in reversed(ordered):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], item) <= 0:
            upper.pop()
        upper.append(item)
    return [item[2] for item in lower[:-1] + upper[:-1]]


def run_rg(rg_bin, mesh, workdir, maxd, maxa, minr, repaired_mesh=None):
    command = [rg_bin, mesh, str(maxd), str(maxa), str(minr)]
    if repaired_mesh:
        command.append(repaired_mesh)
    subprocess.run(command,
                   cwd=workdir, check=True, capture_output=True, text=True)
    R = np.genfromtxt(os.path.join(workdir, "regions.csv"), delimiter=",", names=True)
    F = np.genfromtxt(os.path.join(workdir, "faces.csv"), delimiter=",", names=True)
    return R, F


def merge_coplanar(R, cop_ang, cop_off, min_member_area=0.0,
                   max_vertical_component=None):
    area = np.atleast_1d(R["area"])
    N = np.stack([R["nx"], R["ny"], R["nz"]], 1)
    C = np.stack([R["cx"], R["cy"], R["cz"]], 1)
    N = N / np.linalg.norm(N, axis=1, keepdims=True)
    # Plane orientation is unsigned. Canonical signs avoid cancellation when
    # disconnected mesh patches have opposite winding.
    dominant = np.argmax(np.abs(N), axis=1)
    signs = np.where(N[np.arange(len(N)), dominant] < 0.0, -1.0, 1.0)
    N = N * signs[:, None]
    mask = area >= min_member_area
    if max_vertical_component is not None:
        mask &= np.abs(N[:, 1]) <= max_vertical_component
    source_indices = np.flatnonzero(mask)
    area, N, C = area[mask], N[mask], C[mask]
    n = len(area)
    parent = list(range(n))
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x
    cosA = math.cos(math.radians(cop_ang))
    # Vectorized comparisons keep memory linear and make thousands of CGAL
    # regions practical. The symmetric distance prevents a noisy tilted patch
    # from absorbing a distinct parallel surface.
    for i in range(n):
        if i + 1 >= n:
            break
        delta = C[i + 1:] - C[i]
        angular = np.abs(N[i + 1:] @ N[i]) > cosA
        first_distance = np.abs(delta @ N[i]) < cop_off
        second_distance = np.abs(np.einsum("ij,ij->i", delta, N[i + 1:])) < cop_off
        for j in np.flatnonzero(angular & first_distance & second_distance) + i + 1:
            parent[find(int(j))] = find(i)
    groups = defaultdict(list)
    for i in range(n):
        groups[find(i)].append(i)
    out = []
    for mem in groups.values():
        w = area[mem]; a = float(w.sum())
        nn = (N[mem] * w[:, None]).sum(0); nn = nn / np.linalg.norm(nn)
        cc = (C[mem] * w[:, None]).sum(0) / w.sum()
        out.append({
            "area": a,
            "n": nn,
            "c": cc,
            "mem": set(int(source_indices[m]) for m in mem),
        })
    out.sort(key=lambda p: -p["area"])
    return out


def build_corners(plane, F):
    freg = F["region"].astype(int)
    fc = np.stack([F["cx"], F["cy"], F["cz"]], 1)
    pts = fc[np.isin(freg, list(plane["mem"]))]
    if len(pts) < 3:
        return None, 0.0, 0.0
    nn = plane["n"]; up = np.array([0, 1., 0])
    v = up - (up @ nn) * nn
    v = v / np.linalg.norm(v) if np.linalg.norm(v) > 1e-6 else np.cross(nn, [1, 0, 0])
    u = np.cross(v, nn)
    uv = np.stack([(pts - plane["c"]) @ u, (pts - plane["c"]) @ v], 1)
    h = np.asarray(convex_hull_indices(uv), dtype=int)
    if len(h) < 3:
        return None, 0.0, 0.0
    corners = [(plane["c"] + u * uv[i, 0] + v * uv[i, 1]).tolist() for i in h]
    w = float(uv[h, 0].max() - uv[h, 0].min())
    hh = float(uv[h, 1].max() - uv[h, 1].min())
    return corners, w, hh


def attach_support_bounds(planes, F):
    """Attach per-plane y/tangent bounds in one linear pass over mesh faces."""
    if not planes or len(np.atleast_1d(F)) == 0:
        return planes
    regions = np.atleast_1d(F["region"]).astype(int)
    centers = np.stack([F["cx"], F["cy"], F["cz"]], 1)
    max_region = max(
        int(regions.max(initial=-1)),
        max((max(plane["mem"], default=-1) for plane in planes), default=-1),
    )
    region_to_plane = np.full(max_region + 1, -1, dtype=int)
    for plane_index, plane in enumerate(planes):
        members = np.fromiter(plane["mem"], dtype=int)
        if len(members):
            region_to_plane[members] = plane_index
    valid_region = (regions >= 0) & (regions < len(region_to_plane))
    plane_indices = np.full(len(regions), -1, dtype=int)
    plane_indices[valid_region] = region_to_plane[regions[valid_region]]
    valid = plane_indices >= 0
    if not np.any(valid):
        return planes
    plane_indices = plane_indices[valid]
    centers = centers[valid]
    normals = np.asarray([plane["n"] for plane in planes], dtype=float)
    directions = np.stack([normals[:, 2], -normals[:, 0]], axis=1)
    directions /= np.maximum(np.linalg.norm(directions, axis=1, keepdims=True), 1e-12)
    tangents = np.einsum("ij,ij->i", centers[:, [0, 2]], directions[plane_indices])
    count = len(planes)
    y_min = np.full(count, np.inf)
    y_max = np.full(count, -np.inf)
    t_min = np.full(count, np.inf)
    t_max = np.full(count, -np.inf)
    np.minimum.at(y_min, plane_indices, centers[:, 1])
    np.maximum.at(y_max, plane_indices, centers[:, 1])
    np.minimum.at(t_min, plane_indices, tangents)
    np.maximum.at(t_max, plane_indices, tangents)
    for index, plane in enumerate(planes):
        if np.isfinite(y_min[index]):
            plane["support_bounds"] = {
                "y_min": float(y_min[index]),
                "y_max": float(y_max[index]),
                "t_min": float(t_min[index]),
                "t_max": float(t_max[index]),
            }
    return planes


def classify_plane(plane, main_normal):
    """Classify a candidate before applying type-specific support filters."""
    tilt = abs(float(plane["n"] @ [0, 1, 0]))
    if tilt > 0.30:
        return "falda"
    if abs(float(plane["n"] @ main_normal)) > 0.5:
        return "facciata"
    return "spalla"


def filter_candidates_by_area(planes, min_area):
    """Apply only a scale-local noise floor; semantic labels are irrelevant."""
    return [plane for plane in planes if plane["area"] >= min_area]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mesh")
    ap.add_argument("out")
    ap.add_argument("--rg", default=RG_DEFAULT)
    ap.add_argument("--maxd", type=float,
                    help="distanza Region Growing; default derivato dalla mesh")
    ap.add_argument("--maxa", type=float, default=25.0)
    ap.add_argument("--minr", type=int, default=25)
    ap.add_argument("--min-area", type=float, default=0.05)  # unità OC² (~1.8 m²)
    ap.add_argument("--cop-ang", type=float, default=8.0)
    ap.add_argument("--cop-off", type=float, default=0.08)
    ap.add_argument("--repaired-mesh",
                    help="scrive una copia geometricamente identica e manifold")
    ap.add_argument("--metric", action="store_true",
                    help="la mesh di ingresso e' gia' espressa in metri")
    ap.add_argument("--support-only", action="store_true",
                    help="salta i gusci convessi; posizione e normale bastano alla fusione")
    args = ap.parse_args()

    max_distance = args.maxd
    if max_distance is None:
        max_distance = estimate_mesh_resolution(args.mesh) * 1.5
        print(f"Region Growing maxd auto: {max_distance:.5f}")

    with tempfile.TemporaryDirectory(prefix="cgalplanes_") as wd:
        R, F = run_rg(args.rg, args.mesh, wd, max_distance, args.maxa, args.minr,
                      args.repaired_mesh)
        merged = merge_coplanar(
            R, args.cop_ang, args.cop_off,
            min_member_area=args.min_area,
            max_vertical_component=0.50,
        )
        attach_support_bounds(merged, F)

    vertical = [p for p in merged if abs(float(p["n"] @ [0, 1, 0])) <= 0.35]
    main_vertical = max(vertical, key=lambda p: p["area"], default=None)
    main_n = main_vertical["n"] if main_vertical is not None else np.array([0, 0, 1.])
    candidates = [
        (plane, classify_plane(plane, main_n))
        for plane in filter_candidates_by_area(merged, args.min_area)
    ]

    planes = []
    for i, (p, tipo) in enumerate(candidates):
        if args.support_only:
            corners, w, h = [], 0.0, 0.0
        else:
            corners, w, h = build_corners(p, F)
            if corners is None:
                continue
        nome = {"facciata": "Facciata", "spalla": "Spalletta", "falda": "Falda"}[tipo]
        planes.append({
            "id": i, "nome": f"{nome} {i + 1}", "tipo": tipo,
            "punto": p["c"].tolist(), "normale": p["n"].tolist(),
            "corners": corners, "area_m2": round(p["area"], 4),
            "w": round(w, 3), "h": round(h, 3),
            "support_bounds": p.get("support_bounds"),
        })
    with open(args.out, "w") as f:
        document = {"schema": "cgal_planes", "planes": planes}
        if args.metric:
            document["scale"] = "metric"
        json.dump(document, f)
    print(f"CGAL planes: {len(planes)} -> {args.out}")
    for p in planes[:6]:
        nrm = p["normale"]
        print(f"  {p['nome']:14s} {p['tipo']:9s} n=[{nrm[0]:+.2f},{nrm[1]:+.2f},{nrm[2]:+.2f}] vtx={len(p['corners'])}")


if __name__ == "__main__":
    main()
