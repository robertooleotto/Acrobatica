"""Riconoscimento mesh-aware dei balconi.

Un balcone non è una generica macchia fuori piano: deve avere una soletta
quasi orizzontale, ancorata alla facciata e proiettata verso l'esterno, più
evidenza di un parapetto sul bordo frontale. Questa pipeline lavora sui
triangoli della mesh e non confonde quindi finestre, cornici e modanature con
volumi da estrudere.
"""
from __future__ import annotations

from collections import defaultdict
from math import cos, radians

import numpy as np
from scipy.spatial import cKDTree


DETECTOR_VERSION = "mesh_slab_parapet_v2"


def _basis(plane: dict):
    c = np.asarray(plane["c"], dtype=np.float64)
    n = np.asarray(plane["n"], dtype=np.float64)
    n /= np.linalg.norm(n)
    up = np.asarray(plane["up"], dtype=np.float64)
    up -= n * float(up @ n)
    up /= np.linalg.norm(up)
    right = np.cross(up, n)
    right /= np.linalg.norm(right)
    bounds = tuple(float(x) for x in plane["bounds"])
    return c, n, up, right, bounds


def _components(points: np.ndarray, vertex_ids: np.ndarray, radius: float) -> list[np.ndarray]:
    """Componenti di facce: topologia condivisa + piccoli gap geometrici."""
    count = len(points)
    parent = np.arange(count)
    size = np.ones(count, dtype=np.int32)

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = int(parent[x])
        return x

    def union(a: int, b: int) -> None:
        a, b = find(a), find(b)
        if a == b:
            return
        if size[a] < size[b]:
            a, b = b, a
        parent[b] = a
        size[a] += size[b]

    by_vertex: dict[int, list[int]] = defaultdict(list)
    for face_index, face in enumerate(vertex_ids):
        for vertex in face:
            by_vertex[int(vertex)].append(face_index)
    for linked in by_vertex.values():
        for other in linked[1:]:
            union(linked[0], other)

    if count > 1:
        # La fotogrammetria può lasciare fessure minime nella stessa soletta.
        for a, b in cKDTree(points).query_pairs(radius):
            union(int(a), int(b))

    grouped: dict[int, list[int]] = defaultdict(list)
    for index in range(count):
        grouped[find(index)].append(index)
    return [np.asarray(value, dtype=np.int32) for value in grouped.values()]


def _box_geometry(u0, u1, w0, w1, v0, v1):
    vertices = np.asarray([
        [u0, w0, v0], [u1, w0, v0], [u1, w1, v0], [u0, w1, v0],
        [u0, w0, v1], [u1, w0, v1], [u1, w1, v1], [u0, w1, v1],
    ], dtype=np.float64)
    faces = [
        [0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
        [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7],
    ]
    return vertices, faces


def _local_to_world(local: np.ndarray, c, n, up, right) -> np.ndarray:
    return c + local[:, 0, None] * right + local[:, 1, None] * n + local[:, 2, None] * up


def detect_balconies_from_mesh(
    vertices: np.ndarray,
    faces: np.ndarray,
    plane: dict,
    *,
    min_projection_m: float = 0.45,
    max_projection_m: float = 1.80,
    min_width_m: float = 0.80,
    max_width_m: float = 6.00,
    min_slab_area_m2: float = 0.08,
    max_horizontal_angle_deg: float = 25.0,
    cluster_radius_m: float = 0.32,
    ppm: float = 110.0,
) -> dict:
    """Rileva solette con parapetto e costruisce la geometria dei balconi."""
    V = np.asarray(vertices, dtype=np.float64).reshape(-1, 3)
    F = np.asarray(faces, dtype=np.int64).reshape(-1, 3)
    if len(V) == 0 or len(F) == 0:
        raise ValueError("La mesh deve contenere vertici e facce triangolari")
    if F.min() < 0 or F.max() >= len(V):
        raise ValueError("Indici faccia fuori dall'intervallo dei vertici")
    if not 0 < min_projection_m < max_projection_m:
        raise ValueError("Intervallo di profondità balcone non valido")
    if ppm <= 0:
        raise ValueError("ppm deve essere > 0")

    c, n, up, right, bounds = _basis(plane)
    u_min, u_max, v_min, v_max = bounds
    tri = V[F]
    cross = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    norm = np.linalg.norm(cross, axis=1)
    area = norm / 2.0
    normals = cross / np.maximum(norm[:, None], 1e-12)
    centers = tri.mean(axis=1)
    rel_centers = centers - c
    face_u = rel_centers @ right
    face_v = rel_centers @ up
    face_w = rel_centers @ n

    horizontal = np.abs(normals @ up) >= cos(radians(max_horizontal_angle_deg))
    eligible = (
        horizontal & (area > 3e-4)
        & (face_u >= u_min) & (face_u <= u_max)
        & (face_v >= v_min) & (face_v <= v_max)
        & (face_w >= 0.01) & (face_w <= max_projection_m + 0.9)
    )
    selected_faces = np.flatnonzero(eligible)
    local_centers = np.column_stack([
        face_u[selected_faces], face_w[selected_faces], face_v[selected_faces] * 1.8,
    ])
    components = _components(local_centers, F[selected_faces], cluster_radius_m)

    candidates: list[dict] = []
    for component in components:
        face_indexes = selected_faces[component]
        if len(face_indexes) < 2:
            continue
        points = V[F[face_indexes]].reshape(-1, 3)
        rel = points - c
        uu, ww, vv = rel @ right, rel @ n, rel @ up
        u0, u1 = np.percentile(uu, [1, 99])
        w0, w1 = np.percentile(ww, [1, 99])
        slab_v = float(np.median(vv))
        width = float(u1 - u0)
        projection = float(w1 - min(0.0, w0))
        horizontal_area = float(np.sum(area[face_indexes] * np.abs(normals[face_indexes] @ up)))

        # Deve essere una soletta, non strada/tetto/cornice.
        if not (min_width_m <= width <= max_width_m):
            continue
        if not (min_projection_m <= projection <= max_projection_m):
            continue
        if horizontal_area < min_slab_area_m2 or float(np.ptp(vv)) > 0.45:
            continue
        if w0 > 0.25:  # non è ancorata alla facciata
            continue
        if slab_v < v_min + 1.5 or slab_v > v_max - 1.0:
            continue

        # Parapetto: superficie non orizzontale vicino al bordo frontale e
        # sopra la soletta. Questo è il filtro che elimina davanzali e cornici.
        parapet_band = (
            (face_u >= u0 - 0.18) & (face_u <= u1 + 0.18)
            & (face_w >= w1 - 0.22) & (face_w <= w1 + 0.22)
            & (face_v >= slab_v + 0.05) & (face_v <= slab_v + 1.35)
            & (np.abs(normals @ up) < 0.70)
        )
        parapet_faces = np.flatnonzero(parapet_band)
        parapet_area = float(area[parapet_faces].sum())
        if len(parapet_faces) == 0 or parapet_area < max(0.25, width * 0.25):
            continue
        parapet_height = float(np.clip(
            np.percentile(face_v[parapet_faces], 98) - slab_v, 0.70, 1.20))

        score = min(0.99, 0.62 + 0.12 * min(1.0, horizontal_area / (width * projection))
                    + 0.20 * min(1.0, parapet_area / max(width, 1e-6)))
        candidates.append({
            "u_min": float(u0), "u_max": float(u1),
            "slab_elevation_m": slab_v,
            "projection_depth_m": float(w1),
            "width_m": width,
            "slab_area_m2": horizontal_area,
            "parapet_height_m": parapet_height,
            "parapet_area_m2": parapet_area,
            "confidence_score": float(score),
            "n_slab_faces": int(len(face_indexes)),
            "n_parapet_faces": int(len(parapet_faces)),
        })

    # Una soletta chiusa offre una faccia superiore e una inferiore: entrambe
    # soddisfano i criteri, ma rappresentano lo stesso balcone.
    deduplicated: list[dict] = []
    for item in sorted(candidates, key=lambda value: value["slab_elevation_m"], reverse=True):
        duplicate = False
        for kept in deduplicated:
            overlap = max(0.0, min(item["u_max"], kept["u_max"])
                          - max(item["u_min"], kept["u_min"]))
            min_width = min(item["width_m"], kept["width_m"])
            if (overlap >= 0.70 * min_width
                    and abs(item["projection_depth_m"] - kept["projection_depth_m"]) <= 0.15
                    and abs(item["slab_elevation_m"] - kept["slab_elevation_m"]) <= 0.35):
                duplicate = True
                break
        if not duplicate:
            deduplicated.append(item)
    candidates = sorted(deduplicated,
                        key=lambda item: (item["slab_elevation_m"], item["u_min"]))

    model_vertices: list[list[float]] = []
    model_faces: list[list[int]] = []
    balconies: list[dict] = []
    for index, item in enumerate(candidates, 1):
        u0, u1 = item["u_min"], item["u_max"]
        depth = item["projection_depth_m"]
        slab_v = item["slab_elevation_m"]
        boxes = [
            _box_geometry(u0, u1, 0.0, depth, slab_v - 0.18, slab_v),
            _box_geometry(u0, u1, max(0.0, depth - 0.08), depth,
                          slab_v, slab_v + item["parapet_height_m"]),
        ]
        balcony_faces: list[list[int]] = []
        for local_vertices, faces_local in boxes:
            world = _local_to_world(local_vertices, c, n, up, right)
            offset = len(model_vertices)
            model_vertices.extend(world.tolist())
            for face in faces_local:
                converted = [offset + vertex + 1 for vertex in face]
                model_faces.append(converted)
                balcony_faces.append(converted)

        x0 = (u0 - u_min) * ppm
        x1 = (u1 - u_min) * ppm
        y0 = (v_max - slab_v - item["parapet_height_m"]) * ppm
        y1 = (v_max - slab_v) * ppm
        balconies.append({
            "id": f"balcony-{index}",
            "nome": f"Balcone {index} (mesh)",
            "poly_px": [[x0, y0], [x1, y0], [x1, y1], [x0, y1]],
            "depth_m": depth,
            "depth_mad_cm": 0.0,
            "width_m": item["width_m"],
            "height_m": item["parapet_height_m"],
            "area_m2": item["slab_area_m2"],
            "n_points": item["n_slab_faces"] + item["n_parapet_faces"],
            "confidence": "alta" if item["confidence_score"] >= 0.82 else "media",
            "confidence_score": item["confidence_score"],
            "needs_review": True,
            "slab_elevation_m": slab_v,
            "projection_depth_m": depth,
            "parapet_height_m": item["parapet_height_m"],
            "slab_area_m2": item["slab_area_m2"],
            "faces": balcony_faces,
        })

    obj_lines = ["# Balconi Acrobatica - soletta + parapetto"]
    obj_lines += [f"v {x:.6f} {y:.6f} {z:.6f}" for x, y, z in model_vertices]
    obj_lines += ["f " + " ".join(map(str, face)) for face in model_faces]
    model_json = {
        "detector_version": DETECTOR_VERSION,
        "vertices": model_vertices,
        "faces": model_faces,
        "balconies": balconies,
        "n_vertices": len(model_vertices),
        "n_faces": len(model_faces),
    }
    return {
        "detector_version": DETECTOR_VERSION,
        "count": len(balconies),
        "balconies": balconies,
        "model_json": model_json,
        "obj_text": "\n".join(obj_lines) + "\n",
    }
