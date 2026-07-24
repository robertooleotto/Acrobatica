#!/usr/bin/env python3
"""Run the offline multiscale facade detector and emit the backend plane schema."""

from __future__ import annotations

import argparse
import json
import math
from argparse import Namespace
from pathlib import Path

import numpy as np

from scripts.detect_planes_multiscale import DEFAULT_BINARY, run


def envelope_face_to_plane(face: dict, index: int, scale: float) -> dict:
    corners = np.asarray(face["corners"], dtype=float)
    if corners.shape != (4, 3):
        raise ValueError(f"Faccia involucro {index} non quadrangolare")
    normal = np.asarray(face["normal"], dtype=float)
    normal /= max(float(np.linalg.norm(normal)), 1e-12)
    width = 0.5 * (
        float(np.linalg.norm(corners[1] - corners[0]))
        + float(np.linalg.norm(corners[2] - corners[3]))
    ) * scale
    height = 0.5 * (
        float(np.linalg.norm(corners[3] - corners[0]))
        + float(np.linalg.norm(corners[2] - corners[1]))
    ) * scale
    is_return = face.get("envelope_role") == "return"
    label = "Spalletta" if is_return else "Facciata"
    return {
        "nome": f"{label} {index}",
        "tipo": "spalla" if is_return else "facciata",
        "punto": corners.mean(axis=0).tolist(),
        "normale": normal.tolist(),
        "corners": corners.tolist(),
        "area_m2": width * height,
        "w": width,
        "h": height,
        "triangoli": [],
        "family_id": face.get("family_id"),
        "source_candidate_ids": face.get("source_candidate_ids", []),
        "snapped_junction_ids": face.get("snapped_junction_ids", []),
        "height_aligned": bool(face.get("height_aligned")),
    }


def detect(mesh: Path, output_json: Path, binary: Path, scale: float) -> dict:
    artifacts = output_json.parent / f"{output_json.stem}_multiscale"
    run(Namespace(
        mesh=mesh,
        out=artifacts,
        binary=binary,
        voxel_factor=1.2,
    ))
    candidates = json.loads((artifacts / "candidates.json").read_text())
    corrected = json.loads((artifacts / "candidates.v2.json").read_text())
    faces = corrected.get("envelope_faces") or []
    if not faces:
        raise RuntimeError("La pipeline multiscala non ha prodotto superfici d'involucro")
    planes = [
        envelope_face_to_plane(face, index, scale)
        for index, face in enumerate(faces, 1)
    ]
    document = {
        "schema": "acro.planes.multiscale/v1",
        "up": candidates.get("up", [0.0, 1.0, 0.0]),
        "planes": planes,
        "diagnostics": {
            "candidate_count": len(candidates.get("candidates", [])),
            "family_count": len(candidates.get("families", [])),
            "envelope_face_count": len(faces),
            "median_edge": candidates.get("median_edge"),
            "voxel_size": candidates.get("voxel_size"),
        },
    }
    output_json.write_text(json.dumps(document, indent=2))
    return document


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mesh", type=Path)
    parser.add_argument("--out", type=Path, required=True, help="File JSON di output")
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--scale", type=float, required=True)
    args = parser.parse_args()
    if not math.isfinite(args.scale) or args.scale <= 0.0:
        parser.error("--scale deve essere positivo")
    detect(args.mesh.resolve(), args.out.resolve(), args.binary.resolve(), args.scale)


if __name__ == "__main__":
    main()
