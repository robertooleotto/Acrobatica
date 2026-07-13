"""Proiezione foto → piani facciata (passo 8).

Questo modulo raccoglie gli input da R2/Supabase e orchestra il baker headless:

    sessions/<id>/photos/*.jpg            ← foto (tabella facade_photos)
    sessions/<id>/out/mesh/clean/*        ← mesh PULITA (dall'editor)
    sessions/<id>/out/mesh/raw/oc_poses.json  ← pose Object Capture
    sessions/<id>/out/planes.json         ← piani decisi nell'editor

`gather_inputs()` valida la disponibilità; `project()` scarica, esegue il mosaico
validato nel NativePoseMeshViewer e pubblica OBJ/MTL/PNG in `out/projection`.
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Optional

from . import ortho_bake, session_state, session_store, storage_service


class InputsMissing(RuntimeError):
    pass


class ProjectionError(RuntimeError):
    pass


_CONTENT_TYPES = {
    ".obj": "model/obj",
    ".mtl": "model/mtl",
    ".png": "image/png",
    ".txt": "text/plain",
    ".json": "application/json",
}


def _mesh_entry(result: dict | None, kind: str) -> dict:
    """result['mesh'] normalizzato → il gruppo `kind` ({raw|clean})."""
    mesh = (result or {}).get("mesh") or {}
    if "files" in mesh and "raw" not in mesh and "clean" not in mesh:
        mesh = {"raw": mesh}          # compat forma piatta legacy = raw
    return mesh.get(kind) or {}


def _file_in(entry: dict, name: str) -> Optional[str]:
    """Path storage del file `name` dentro un gruppo mesh, o None."""
    for f in entry.get("files", []):
        if isinstance(f, dict) and Path(f.get("name", "")).name == name:
            return f.get("path")
    return None


def _mesh_main_path(entry: dict) -> Optional[str]:
    main = entry.get("main_obj")
    return _file_in(entry, main) if main else None


def gather_inputs(session_id: str) -> Optional[dict]:
    """Raccoglie e verifica i 4 input dal cloud. Ritorna None se la sessione non
    esiste (→ il chiamante risponde 404). Altrimenti un dict:
        {ready: bool, status: str, inputs: [ {kind, present, detail, paths} ], missing: [str]}
    """
    sess = session_store.get_session(session_id)
    if sess is None:
        return None
    result = sess.get("result") or {}
    inputs: list[dict] = []
    missing: list[str] = []

    def add(kind: str, present: bool, detail: str, paths: list[str] | None = None):
        inputs.append({"kind": kind, "present": present,
                       "detail": detail, "paths": paths or []})
        if not present:
            missing.append(kind)

    # 1) FOTO — conta dal DB, scarica la prima per provare l'accesso allo storage.
    photos = session_store.list_photos(session_id)
    if photos:
        first = photos[0]["storage_path"]
        try:
            b = storage_service.download_bytes(first)
            add("photos", True, f"{len(photos)} foto (prima scaricata: {len(b)} B)", [first])
        except Exception as e:
            add("photos", False, f"{len(photos)} foto in DB ma storage non leggibile: {str(e)[:60]}", [first])
    else:
        add("photos", False, "nessuna foto registrata per la sessione")

    # 2) MESH PULITA — l'OBJ principale del gruppo `clean`.
    clean = _mesh_entry(result, "clean")
    obj_path = _mesh_main_path(clean)
    if obj_path:
        size = storage_service.head_size(obj_path)
        if size is not None:
            add("mesh_clean", True, f"{clean.get('main_obj')} ({size} B)", [obj_path])
        else:
            add("mesh_clean", False, f"manifest presente ma {obj_path} non su storage", [obj_path])
    else:
        add("mesh_clean", False, "mesh pulita non caricata (salvala dall'editor)")

    # 3) POSE OC — oc_poses.json nel gruppo mesh raw.
    poses_path = _file_in(_mesh_entry(result, "raw"), "oc_poses.json")
    if poses_path:
        try:
            data = storage_service.download_bytes(poses_path)
            n = len(json.loads(data))
            add("poses", True, f"{n} pose", [poses_path])
        except Exception as e:
            add("poses", False, f"oc_poses.json non leggibile/parsabile: {str(e)[:60]}", [poses_path])
    else:
        add("poses", False, "oc_poses.json assente (deve arrivare con la mesh raw da Object Capture)")

    # 4) PIANI — out/planes.json salvato dall'editor.
    planes_path = (result.get("planes") or {}).get("path")
    if planes_path:
        try:
            data = storage_service.download_bytes(planes_path)
            doc = json.loads(data)
            n = len(doc.get("planes", []))
            add("planes", n > 0, f"{n} piani (schema {doc.get('schema', '?')})", [planes_path])
        except Exception as e:
            add("planes", False, f"planes.json non leggibile/parsabile: {str(e)[:60]}", [planes_path])
    else:
        add("planes", False, "piani non salvati (usa 'Salva piani sul cloud' nell'editor)")

    return {
        "ready": not missing,
        "status": sess.get("status") or "",
        "inputs": inputs,
        "missing": missing,
    }


def _download_inputs(session_id: str, sess: dict, root: Path) -> dict:
    result = sess.get("result") or {}
    clean = _mesh_entry(result, "clean")
    mesh_path = _mesh_main_path(clean)
    poses_path = _file_in(_mesh_entry(result, "raw"), "oc_poses.json")
    planes_path = (result.get("planes") or {}).get("path")
    photos = session_store.list_photos(session_id)
    missing = []
    if not mesh_path:
        missing.append("mesh_clean")
    if not poses_path:
        missing.append("poses")
    if not planes_path:
        missing.append("planes")
    if not photos:
        missing.append("photos")
    if missing:
        raise InputsMissing("Input mancanti per la proiezione: " + ", ".join(missing))

    mesh = root / "mesh.obj"
    mesh.write_bytes(storage_service.download_bytes(mesh_path))
    poses = json.loads(storage_service.download_bytes(poses_path))
    planes = json.loads(storage_service.download_bytes(planes_path))
    if not planes.get("planes"):
        raise InputsMissing("Il documento dei piani non contiene piani proiettabili")

    photos_dir = root / "photos"
    photos_dir.mkdir()
    for photo in photos:
        index = int(photo["order_index"])
        metadata = photo.get("metadata") or {}
        if isinstance(metadata, str):
            try:
                metadata = json.loads(metadata)
            except ValueError:
                metadata = {}
        pose = poses.get(str(index))
        if pose is not None and metadata.get("image_width") and metadata.get("image_height"):
            pose["image_width_height"] = [
                int(metadata["image_width"]), int(metadata["image_height"])]
        (photos_dir / f"{index:04d}.jpg").write_bytes(
            storage_service.download_bytes(photo["storage_path"])
        )
    return {"mesh": mesh, "poses": poses, "planes": planes,
            "photos": photos_dir, "photo_count": len(photos)}


def project(session_id: str) -> dict:
    """Esegue il mosaico e pubblica il bundle texturizzato dei piani."""
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")

    try:
        current = sess.get("status") or ""
        if current in {session_state.PLANES_READY, session_state.COMPLETED}:
            session_store.update_status(session_id, session_state.MAPPING)

        with tempfile.TemporaryDirectory(prefix="acro_projection_") as td:
            root = Path(td)
            inp = _download_inputs(session_id, sess, root)
            out_dir = root / "output"
            scale = float(inp["planes"].get(
                "scale_m_per_mesh_unit",
                os.environ.get("ACRO_OC_SCALE", "6.0927"),
            ))
            summary = ortho_bake.bake_planes(
                str(inp["mesh"]), inp["poses"], str(inp["photos"]),
                inp["planes"], str(out_dir), texel_mm=8.0,
                max_photos=60, occlusion=False, facing_min=0.342,
                crop=0.9, scale_m_per_mesh_unit=scale,
            )
            if summary["count"] == 0:
                raise ProjectionError("Nessun piano ha prodotto una texture")

            files = []
            for local in sorted(out_dir.iterdir()):
                if not local.is_file():
                    continue
                remote = storage_service.out_path(
                    session_id, f"projection/{local.name}")
                storage_service.upload_bytes(
                    remote, local.read_bytes(),
                    _CONTENT_TYPES.get(local.suffix.lower(), "application/octet-stream"),
                )
                files.append({"name": local.name, "path": remote,
                              "size": local.stat().st_size})

            manifest = {
                "main_obj": summary["main_obj"],
                "files": files,
                "planes": summary["planes"],
                "total_area_m2": summary["total_area_m2"],
                "coverage": summary["coverage"],
                "photo_count": inp["photo_count"],
                "scale_m_per_mesh_unit": scale,
            }
            latest = session_store.get_session(session_id) or sess
            result = latest.get("result") or {}
            result["projection"] = manifest
            session_store.update_session(session_id, {"result": result})

        try:
            row = session_store.update_status(session_id, session_state.COMPLETED)
            status = row.get("status", session_state.COMPLETED)
        except Exception:
            status = (session_store.get_session(session_id) or {}).get("status", "")

        public_files = [
            {
                "name": f["name"],
                "url": storage_service.signed_url(f["path"], expires_in_sec=3600),
                "size_bytes": f["size"],
            }
            for f in files
        ]
        main = next((f for f in public_files if f["name"] == summary["main_obj"]), None)
        return {
            "status": status,
            "count": summary["count"],
            "total_area_m2": summary["total_area_m2"],
            "coverage": summary["coverage"],
            "main_obj": main,
            "files": public_files,
            "planes": summary["planes"],
        }
    except (InputsMissing, ProjectionError):
        raise
    except Exception as exc:
        raise ProjectionError(f"Proiezione non riuscita: {exc}") from exc
