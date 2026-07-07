#!/usr/bin/env python3
"""Runner della PROIEZIONE (passo 8) — gira sul Mac (opzione A), dove c'è il
binario del NativePoseMeshViewer. Orchestra tutto scaricando/ricaricando da R2:

  1. scarica da storage i 4 input della sessione: foto, mesh pulita, pose OC
     (oc_poses.json), piani decisi (planes.json);
  2. ponte planes.json → OBJ a gruppi (frame OC) [scripts.planes_json_to_obj];
  3. bake ortofoto per piano col viewer headless (--headless);
  4. ricarica su R2 le ortofoto (out/ortho/…), registra result.ortho, avanza a
     `completed`.

Uso:  python -m scripts.run_projection --session <id> [--res 8] [--max-photos 60]
      [--dry]   (solo scarica+valida, non bake/carica)

Prerequisiti: backend/.env con STORAGE_BACKEND=s3 (R2), e il viewer buildato
(swift build -c release in tools/NativePoseMeshViewer).
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")
from app.services import session_store, storage_service, projection_service, session_state

REPO = Path(__file__).resolve().parents[2]
VIEWER = REPO / "tools/NativePoseMeshViewer/.build/release/NativePoseMeshViewer"

_ORTHO_CT = {".png": "image/png", ".jpg": "image/jpeg", ".txt": "text/plain",
             ".obj": "model/obj", ".mtl": "model/mtl"}


def _download_inputs(sid: str, result: dict, workdir: Path) -> dict:
    """Scarica i 4 input in `workdir`. Ritorna i path locali; solleva se manca qualcosa."""
    # mesh pulita (geometria + occlusore). Se non c'è la pulita, ripiega sulla grezza.
    clean = projection_service._mesh_entry(result, "clean")
    raw = projection_service._mesh_entry(result, "raw")
    mesh_entry = clean if clean.get("files") else raw
    mesh_obj = projection_service._mesh_main_path(mesh_entry)
    if not mesh_obj:
        raise RuntimeError("mesh non trovata (né clean né raw)")
    mesh_dir = workdir / "mesh"
    mesh_dir.mkdir(parents=True, exist_ok=True)
    mesh_local = None
    for f in mesh_entry.get("files", []):
        name = f["name"] if isinstance(f, dict) else f
        path = f.get("path") if isinstance(f, dict) else None
        if not path:
            continue
        dst = mesh_dir / Path(name).name
        dst.write_bytes(storage_service.download_bytes(path))
        if path == mesh_obj:
            mesh_local = dst
    if mesh_local is None:
        raise RuntimeError("OBJ principale della mesh non scaricato")

    # pose OC (oc_poses.json nel gruppo raw)
    poses_path = projection_service._file_in(raw, "oc_poses.json")
    if not poses_path:
        raise RuntimeError("oc_poses.json assente")
    poses_local = workdir / "oc_poses.json"
    poses_local.write_bytes(storage_service.download_bytes(poses_path))

    # piani decisi
    planes_path = (result.get("planes") or {}).get("path")
    if not planes_path:
        raise RuntimeError("planes.json assente (salva i piani dall'editor)")
    planes_local = workdir / "planes.json"
    planes_local.write_bytes(storage_service.download_bytes(planes_path))

    # foto → NNNN.jpg (il viewer le indicizza per numero = order_index = chiave posa)
    photos_dir = workdir / "photos"
    photos_dir.mkdir(exist_ok=True)
    photos = session_store.list_photos(sid)
    if not photos:
        raise RuntimeError("nessuna foto per la sessione")
    for p in photos:
        oi = int(p["order_index"])
        (photos_dir / f"{oi:04d}.jpg").write_bytes(
            storage_service.download_bytes(p["storage_path"]))

    return {"mesh": mesh_local, "poses": poses_local, "planes": planes_local,
            "photos": photos_dir, "n_photos": len(photos)}


def _upload_ortho(sid: str, out_dir: Path) -> dict:
    """Carica gli output del bake su R2 in out/ortho/. Ritorna il manifest."""
    files = []
    for f in sorted(out_dir.iterdir()):
        if not f.is_file():
            continue
        remote = storage_service.out_path(sid, f"ortho/{f.name}")
        ct = _ORTHO_CT.get(f.suffix.lower(), "application/octet-stream")
        storage_service.upload_bytes(remote, f.read_bytes(), ct)
        files.append({"name": f.name, "path": remote, "size": f.stat().st_size})
    return {"files": files}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--session", required=True)
    ap.add_argument("--res", type=float, default=8.0, help="mm/texel")
    ap.add_argument("--max-photos", type=int, default=60)
    ap.add_argument("--dry", action="store_true", help="scarica+valida, niente bake/upload")
    args = ap.parse_args()

    if not VIEWER.exists() and not args.dry:
        sys.exit(f"viewer non buildato: {VIEWER}\n  → cd tools/NativePoseMeshViewer && swift build -c release")

    sid = args.session
    sess = session_store.get_session(sid)
    if sess is None:
        sys.exit(f"sessione {sid} non trovata")
    result = sess.get("result") or {}

    with tempfile.TemporaryDirectory(prefix="acro_proj_") as td:
        work = Path(td)
        print(f"[1/4] scarico input da storage …")
        inp = _download_inputs(sid, result, work)
        print(f"      mesh={inp['mesh'].name}  pose ok  planes ok  foto={inp['n_photos']}")

        print(f"[2/4] ponte planes.json → OBJ a gruppi (frame OC) …")
        piani_obj = work / "piani.obj"
        subprocess.run([sys.executable, "-m", "scripts.planes_json_to_obj",
                        "--planes", str(inp["planes"]), "--mesh", str(inp["mesh"]),
                        "--out", str(piani_obj)], check=True, cwd=".")

        if args.dry:
            print("[dry] stop prima del bake."); return

        out_dir = work / "ortho"
        print(f"[3/4] bake ortofoto (viewer headless, {args.res}mm/texel) …")
        subprocess.run([str(VIEWER), "--headless",
                        "--mesh", str(piani_obj), "--full-mesh", str(inp["mesh"]),
                        "--poses", str(inp["poses"]), "--photos", str(inp["photos"]),
                        "--out", str(out_dir), "--res", str(args.res),
                        "--max-photos", str(args.max_photos)], check=True)
        if not out_dir.exists() or not any(out_dir.glob("*.png")):
            sys.exit("bake non ha prodotto ortofoto")

        print(f"[4/4] carico ortofoto su R2 (out/ortho/) …")
        manifest = _upload_ortho(sid, out_dir)
        result["ortho"] = manifest
        session_store.update_session(sid, {"result": result})
        try:
            session_store.update_status(sid, session_state.COMPLETED)
        except Exception:
            pass
        print(f"[OK] {len(manifest['files'])} file caricati in "
              f"sessions/{sid}/out/ortho/ · sessione → completed")


if __name__ == "__main__":
    main()
