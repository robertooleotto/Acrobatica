"""Regularizzazione geometrica delle catene di facciata."""
from __future__ import annotations

import copy

import numpy as np


def _unit(value: np.ndarray) -> np.ndarray:
    length = float(np.linalg.norm(value))
    return value / length if length > 1e-9 else value


def _quad_vertical_edges(corners: np.ndarray, up: np.ndarray):
    """Restituisce le due coppie (basso, alto) del quad, conservando gli indici."""
    pairs = (((0, 1), (2, 3)), ((1, 2), (3, 0)))

    def score(pairing):
        return sum(abs(float(np.dot(_unit(corners[b] - corners[a]), up)))
                   for a, b in pairing)

    vertical = max(pairs, key=score)
    result = []
    for a, b in vertical:
        if float(np.dot(corners[b] - corners[a], up)) >= 0:
            result.append((a, b))
        else:
            result.append((b, a))
    return result


def _wall_quad(plane: dict, up: np.ndarray):
    raw = plane.get("corners")
    corners = np.asarray(raw, dtype=float) if isinstance(raw, list) else np.empty((0, 3))
    if corners.shape != (4, 3):
        return None
    normal = np.asarray(plane.get("normale", []), dtype=float)
    if normal.shape != (3,) or np.linalg.norm(normal) < 1e-9:
        return None
    if abs(float(np.dot(_unit(normal), up))) >= 0.65:
        return None
    return corners


def _shared_vertical_edge(a: np.ndarray, b: np.ndarray, up: np.ndarray,
                          tolerance: float) -> bool:
    edges_a = _quad_vertical_edges(a, up)
    edges_b = _quad_vertical_edges(b, up)
    for alo, ahi in edges_a:
        for blo, bhi in edges_b:
            direct = np.linalg.norm(a[alo] - b[blo]) + np.linalg.norm(a[ahi] - b[bhi])
            if direct <= tolerance * 2:
                return True
    return False


def _regularize_run(planes: list[dict], indices: list[int], up: np.ndarray) -> np.ndarray:
    edge_vectors = []
    edge_lengths = []
    edge_records = []
    for index in indices:
        corners = np.asarray(planes[index]["corners"], dtype=float)
        records = _quad_vertical_edges(corners, up)
        edge_records.append((index, corners, records))
        for low, high in records:
            vector = corners[high] - corners[low]
            if np.dot(vector, up) < 0:
                vector = -vector
            length = float(np.linalg.norm(vector))
            if length > 1e-8:
                edge_vectors.append(vector / length)
                edge_lengths.append(length)

    if not edge_vectors:
        return up
    extrusion = _unit(np.average(np.asarray(edge_vectors), axis=0,
                                 weights=np.asarray(edge_lengths)))
    if np.dot(extrusion, up) < 0:
        extrusion = -extrusion

    lows = []
    highs = []
    for _, corners, records in edge_records:
        for low, high in records:
            lows.append(float(np.dot(corners[low], extrusion)))
            highs.append(float(np.dot(corners[high], extrusion)))
    lower = float(np.median(lows))
    upper = float(np.median(highs))
    if upper <= lower + 1e-8:
        return extrusion

    for index, corners, records in edge_records:
        updated = corners.copy()
        for low, high in records:
            base = corners[low] + extrusion * (lower - np.dot(corners[low], extrusion))
            updated[low] = base
            updated[high] = base + extrusion * (upper - lower)

        old_normal = _unit(np.asarray(planes[index]["normale"], dtype=float))
        first_low, _ = records[0]
        second_low, _ = records[1]
        horizontal = updated[second_low] - updated[first_low]
        normal = _unit(np.cross(horizontal, extrusion))
        if np.dot(normal, old_normal) < 0:
            normal = -normal
        planes[index]["corners"] = updated.tolist()
        planes[index]["normale"] = normal.tolist()
        planes[index]["punto"] = updated.mean(axis=0).tolist()
        planes[index]["regularization"] = "shared_rectangular_extrusion"
    return extrusion


def regularize_planes_document(document: dict) -> dict:
    """Rende rettangolari le catene ordinate di quad verticali saldati.

    Le catene scollegate mantengono quota ed elevazione indipendenti; vengono
    regolarizzati insieme soltanto piani consecutivi che condividono un edge.
    """
    output = copy.deepcopy(document)
    planes = output.get("planes")
    if not isinstance(planes, list) or len(planes) < 2:
        return output
    base = output.get("piano_base") or {}
    up = _unit(np.asarray(base.get("up", [0.0, 1.0, 0.0]), dtype=float))
    if up.shape != (3,) or np.linalg.norm(up) < 1e-9:
        up = np.array([0.0, 1.0, 0.0])

    all_points = [point for plane in planes for point in (plane.get("corners") or [])
                  if isinstance(point, list) and len(point) == 3]
    diagonal = (float(np.linalg.norm(np.ptp(np.asarray(all_points), axis=0)))
                if all_points else 1.0)
    tolerance = max(diagonal * 0.01, 1e-5)

    runs = []
    current = []
    for index, plane in enumerate(planes):
        corners = _wall_quad(plane, up)
        if corners is None:
            if len(current) >= 2:
                runs.append(current)
            current = []
            continue
        if not current:
            current = [index]
            continue
        previous = _wall_quad(planes[current[-1]], up)
        if previous is not None and _shared_vertical_edge(previous, corners, up, tolerance):
            current.append(index)
        else:
            if len(current) >= 2:
                runs.append(current)
            current = [index]
    if len(current) >= 2:
        runs.append(current)

    directions = [_regularize_run(planes, run, up) for run in runs]
    if directions:
        shared = _unit(np.mean(np.asarray(directions), axis=0))
        if np.dot(shared, up) < 0:
            shared = -shared
        output["shared_extrusion_direction"] = shared.tolist()
    return output
