"""Test locale keystone su UNA foto di una sessione Supabase.
Usa il modulo `app.services.keystone_correction` (stesso path di produzione).

Uso:
    python scripts/run_keystone_one.py <session_id_prefix> [order_index]
"""
from __future__ import annotations
import sys
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import cv2
import numpy as np
from dotenv import load_dotenv

load_dotenv(ROOT / ".env")

from app.services import session_store, storage_service
from app.services.keystone_correction import keystone_correct
from app.supabase_client import get_supabase


def resolve_session_id(prefix: str) -> str:
    res = get_supabase().table("facade_sessions").select("id").execute()
    matches = [r["id"] for r in (res.data or []) if r["id"].startswith(prefix)]
    if not matches:
        raise SystemExit(f"Nessuna sessione con prefisso {prefix}")
    if len(matches) > 1:
        raise SystemExit(f"Prefisso ambiguo: {matches}")
    return matches[0]


def main(prefix: str, order: int | None) -> None:
    sid = resolve_session_id(prefix)
    photos = session_store.list_photos(sid)
    if not photos:
        raise SystemExit("Nessuna foto.")

    if order is None:
        p = max(photos, key=lambda q: abs(float((q["metadata"].get("euler_angles") or [0])[0])))
    else:
        p = next((q for q in photos if q["order_index"] == order), None)
        if p is None:
            raise SystemExit(f"order_index {order} non trovato")

    m = p["metadata"]
    order = p["order_index"]
    print(f"Sessione: {sid}")
    print(f"Foto:     order={order}  euler(deg)={m.get('euler_angles')}")
    print(f"wall_normal_world: {m.get('wall_normal_world')}")
    print(f"metadata image_size: {m.get('image_width')}x{m.get('image_height')}")

    raw = storage_service.download_bytes(p["storage_path"])
    img = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise SystemExit("decode fallito")
    print(f"buffer: {img.shape[1]}x{img.shape[0]}")

    rectified, info = keystone_correct(
        img,
        intrinsics=m["camera_intrinsics"],
        camera_transform=m["camera_transform"],
        wall_normal_world=m.get("wall_normal_world"),
        metadata_image_size=(int(m["image_width"]), int(m["image_height"])),
    )
    print(f"pre_rotated_cw:   {info.pre_rotated_cw}")
    print(f"used_wall_normal: {info.used_wall_normal}")
    print(f"output:           {info.output_size[0]}x{info.output_size[1]}")

    out_dir = Path(f"/tmp/keystone_one_{sid[:8]}")
    out_dir.mkdir(parents=True, exist_ok=True)
    orig_path = out_dir / f"{order:02d}_a_orig.jpg"
    rect_path = out_dir / f"{order:02d}_b_rectified.jpg"
    cv2.imwrite(str(orig_path), img)
    cv2.imwrite(str(rect_path), rectified, [cv2.IMWRITE_JPEG_QUALITY, 88])
    print(f"\nOutput in {out_dir}")
    subprocess.run(["open", "-a", "Preview", str(orig_path), str(rect_path)], check=False)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Uso: python scripts/run_keystone_one.py <session_id_prefix> [order_index]")
    order = int(sys.argv[2]) if len(sys.argv) >= 3 else None
    main(sys.argv[1], order)
