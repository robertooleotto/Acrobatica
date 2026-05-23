"""One-off: scarica foto di una sessione da Supabase, applica keystone_correct
localmente, salva originali+raddrizzate in /tmp/keystone_<sid>/ e le apre in
Preview.app per confronto visivo.

Uso:
    cd backend && python scripts/run_keystone_local.py 5a9979cf
(prefisso del session_id sufficiente)
"""
from __future__ import annotations
import os
import sys
import subprocess
from pathlib import Path

# Permetti import del package app/ quando lanciato da backend/
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import cv2
import numpy as np
from dotenv import load_dotenv

load_dotenv(ROOT / ".env")

from app.services.keystone_correction import keystone_correct
from _session_source import SessionSource


def main(arg: str) -> None:
    src = SessionSource.open(arg)
    sid = src.sid
    print(f"Sessione: {src.source_label}")
    photos = src.photos
    print(f"Foto trovate: {len(photos)}")
    if not photos:
        raise SystemExit("Nessuna foto.")

    out_dir = Path(f"/tmp/keystone_{sid[:8]}")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Media normali di sessione (come fa l'endpoint /keystone).
    normals_raw = [p["metadata"].get("wall_normal_world") for p in photos]
    normals_raw = [n for n in normals_raw if n and len(n) == 3]
    session_wall_normal: list[float] | None = None
    if normals_raw:
        ref = np.array(normals_raw[0], dtype=np.float64)
        acc = np.zeros(3, dtype=np.float64)
        for v in normals_raw:
            a = np.array(v, dtype=np.float64)
            if float(np.dot(a, ref)) < 0:
                a = -a
            acc += a
        nn = float(np.linalg.norm(acc))
        if nn > 1e-6:
            session_wall_normal = (acc / nn).tolist()
            print(f"wall_normal_world (media su {len(normals_raw)}/{len(photos)}): "
                  f"{[round(x,3) for x in session_wall_normal]}")
    else:
        print("Nessuna wall_normal_world nelle foto → solo verticali (legacy session)")

    files_to_open: list[str] = []
    for p in photos:
        order = p["order_index"]
        m = p["metadata"]
        intrinsics = m["camera_intrinsics"]
        cam_transform = m.get("camera_transform")
        if cam_transform is None:
            print(f"  [{order}] manca camera_transform, skip")
            continue

        img = src.load_image(p)
        if img is None:
            print(f"  [{order}] decode fallito, skip")
            continue

        orig_path = out_dir / f"{order:02d}_a_orig.jpg"
        rect_path = out_dir / f"{order:02d}_b_keystone.jpg"
        cv2.imwrite(str(orig_path), img)

        rectified, info = keystone_correct(
            img,
            intrinsics=intrinsics,
            camera_transform=cam_transform,
            wall_normal_world=session_wall_normal,
            metadata_image_size=(int(m["image_width"]), int(m["image_height"])),
        )
        cv2.imwrite(str(rect_path), rectified, [cv2.IMWRITE_JPEG_QUALITY, 88])
        euler = m.get("euler_angles") or [0.0, 0.0, 0.0]
        print(f"  [{order}] pitch={euler[0]:+.1f}° roll={euler[2]:+.1f}°  "
              f"in={info.input_size} out={info.output_size}  "
              f"pre_rot={info.pre_rotated_cw} wall_n={info.used_wall_normal}")
        files_to_open.extend([str(orig_path), str(rect_path)])

    print(f"\nOutput in {out_dir}")
    print("Apro in Preview…")
    subprocess.run(["open", "-a", "Preview", *files_to_open], check=False)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Uso: python scripts/run_keystone_local.py <session_prefix|fixture_dir>")
    main(sys.argv[1])
