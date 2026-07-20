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


def run_rg(rg_bin, mesh, workdir, maxd, maxa, minr):
    subprocess.run([rg_bin, mesh, str(maxd), str(maxa), str(minr)],
                   cwd=workdir, check=True, capture_output=True, text=True)
    R = np.genfromtxt(os.path.join(workdir, "regions.csv"), delimiter=",", names=True)
    F = np.genfromtxt(os.path.join(workdir, "faces.csv"), delimiter=",", names=True)
    return R, F


def merge_coplanar(R, cop_ang, cop_off):
    area = np.atleast_1d(R["area"])
    N = np.stack([R["nx"], R["ny"], R["nz"]], 1)
    C = np.stack([R["cx"], R["cy"], R["cz"]], 1)
    N = N / np.linalg.norm(N, axis=1, keepdims=True)
    n = len(area)
    parent = list(range(n))
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x
    cosA = math.cos(math.radians(cop_ang))
    for i in range(n):
        for j in range(i + 1, n):
            if abs(N[i] @ N[j]) > cosA and abs((C[i] - C[j]) @ N[i]) < cop_off:
                parent[find(i)] = find(j)
    groups = defaultdict(list)
    for i in range(n):
        groups[find(i)].append(i)
    out = []
    for mem in groups.values():
        w = area[mem]; a = float(w.sum())
        nn = (N[mem] * w[:, None]).sum(0); nn = nn / np.linalg.norm(nn)
        cc = (C[mem] * w[:, None]).sum(0) / w.sum()
        out.append({"area": a, "n": nn, "c": cc, "mem": set(int(m) for m in mem)})
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
    ap.add_argument("--maxd", type=float, default=0.06)
    ap.add_argument("--maxa", type=float, default=25.0)
    ap.add_argument("--minr", type=int, default=25)
    ap.add_argument("--min-area", type=float, default=0.05)  # unità OC² (~1.8 m²)
    ap.add_argument("--cop-ang", type=float, default=8.0)
    ap.add_argument("--cop-off", type=float, default=0.08)
    args = ap.parse_args()

    with tempfile.TemporaryDirectory(prefix="cgalplanes_") as wd:
        R, F = run_rg(args.rg, args.mesh, wd, args.maxd, args.maxa, args.minr)
        merged = merge_coplanar(R, args.cop_ang, args.cop_off)

    vertical = [p for p in merged if abs(float(p["n"] @ [0, 1, 0])) <= 0.35]
    main_vertical = max(vertical, key=lambda p: p["area"], default=None)
    main_n = main_vertical["n"] if main_vertical is not None else np.array([0, 0, 1.])
    candidates = [
        (plane, classify_plane(plane, main_n))
        for plane in filter_candidates_by_area(merged, args.min_area)
    ]

    planes = []
    for i, (p, tipo) in enumerate(candidates):
        corners, w, h = build_corners(p, F)
        if corners is None:
            continue
        nome = {"facciata": "Facciata", "spalla": "Spalletta", "falda": "Falda"}[tipo]
        planes.append({
            "id": i, "nome": f"{nome} {i + 1}", "tipo": tipo,
            "punto": p["c"].tolist(), "normale": p["n"].tolist(),
            "corners": corners, "area_m2": round(p["area"], 4),
            "w": round(w, 3), "h": round(h, 3),
        })
    with open(args.out, "w") as f:
        json.dump({"schema": "cgal_planes", "planes": planes}, f)
    print(f"CGAL planes: {len(planes)} -> {args.out}")
    for p in planes[:6]:
        nrm = p["normale"]
        print(f"  {p['nome']:14s} {p['tipo']:9s} n=[{nrm[0]:+.2f},{nrm[1]:+.2f},{nrm[2]:+.2f}] vtx={len(p['corners'])}")


if __name__ == "__main__":
    main()
