"""Proiezione foto → piani facciata (passo 8).

SCAFFOLD. Questo modulo raccoglie e verifica gli input della proiezione
**scaricandoli da storage** (R2/Supabase), senza dipendere da file locali:

    sessions/<id>/photos/*.jpg            ← foto (tabella facade_photos)
    sessions/<id>/out/mesh/clean/*        ← mesh PULITA (dall'editor)
    sessions/<id>/out/mesh/raw/oc_poses.json  ← pose Object Capture
    sessions/<id>/out/planes.json         ← piani decisi nell'editor

`gather_inputs()` valida che ci sia tutto e ne fa un riepilogo. L'algoritmo di
mosaico (assialità H, occlusione BVH, copertura) verrà innestato qui, portato
headless dal NativePoseMeshViewer. Finché non c'è, `project()` si ferma al
controllo di prontezza e non altera lo stato della sessione.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

from . import session_store, storage_service


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
