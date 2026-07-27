"""Proiezione foto → piani facciata (passo 8).

Questo modulo raccoglie gli input da R2/Supabase e orchestra il baker headless:

    sessions/<id>/photos/*.jpg            ← foto (tabella facade_photos)
    sessions/<id>/out/mesh/clean/*        ← mesh PULITA (dall'editor, se esiste)
    sessions/<id>/out/mesh/raw/*          ← prima mesh automatica dal worker OC
    sessions/<id>/out/mesh/raw/oc_poses.json  ← pose Object Capture
    sessions/<id>/out/planes.json         ← piani decisi nell'editor

`gather_inputs()` valida la disponibilità; `project()` scarica, esegue il mosaico
validato nel NativePoseMeshViewer e pubblica OBJ/MTL/PNG in `out/projection`.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
import uuid
from datetime import datetime, timezone
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


def invalidate_geometry_outputs(result: dict, clear_planes: bool = False) -> dict:
    """Invalida tutti gli artefatti derivati da mesh e piani.

    La funzione modifica `result` in-place per integrarsi con il documento di
    sessione esistente. Una nuova mesh rende obsoleti anche i piani; una nuova
    revisione dei soli piani conserva invece la mesh pulita.
    """
    if clear_planes:
        result.pop("planes", None)
    for key in (
        "projection",
        "projection_job",
        "metric_openings",
        "opening_detection_job",
    ):
        result.pop(key, None)
    return result

_ACTIVE_JOB_STATES = {"queued", "running"}
_JOB_STALE_SECONDS = int(os.environ.get("ACRO_PROJECTION_STALE_SECONDS", "7200"))


def uses_mac_worker() -> bool:
    """Il bake pesante gira sul Mac salvo override esplicito per sviluppo."""
    return os.environ.get("ACRO_PROJECTION_EXECUTOR", "mac").lower() != "inline"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _job_is_stale(job: dict, now: datetime | None = None) -> bool:
    if job.get("state") not in _ACTIVE_JOB_STATES:
        return False
    raw = job.get("updated_at")
    if not raw:
        return True
    try:
        updated = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
        if updated.tzinfo is None:
            updated = updated.replace(tzinfo=timezone.utc)
    except ValueError:
        return True
    current = now or datetime.now(timezone.utc)
    return (current - updated).total_seconds() > _JOB_STALE_SECONDS


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


def _mesh_obj_path(entry: dict) -> Optional[str]:
    """Trova l'OBJ proiettabile anche quando il main del gruppo e un USDZ."""
    main = entry.get("main_obj")
    if main and Path(main).suffix.lower() == ".obj":
        path = _file_in(entry, main)
        if path:
            return path
    for item in entry.get("files", []):
        if not isinstance(item, dict):
            continue
        if Path(item.get("name", "")).suffix.lower() == ".obj":
            return item.get("path")
    return None


def _file_record(entry: dict, name: str) -> Optional[dict]:
    target = Path(name).name
    for item in entry.get("files", []):
        if isinstance(item, dict) and Path(item.get("name", "")).name == target:
            return item
    return None


def validate_oc_bundle(result: dict) -> dict:
    """Verifica che modello e pose siano l'output atomico dello stesso job OC."""
    raw = _mesh_entry(result, "raw")
    manifest_record = _file_record(raw, "oc_bundle_manifest.json")
    if manifest_record is None:
        raise InputsMissing(
            "Mesh OC legacy senza manifesto mesh+pose: ricalcolare Object Capture "
            "prima della proiezione"
        )
    try:
        document = json.loads(
            storage_service.download_bytes(manifest_record["path"]),
        )
    except Exception as exc:
        raise InputsMissing(f"Manifesto del pacchetto OC non leggibile: {exc}") from exc
    if document.get("schema") != "acro.oc-bundle/v1" or not document.get("bundle_id"):
        raise InputsMissing("Manifesto del pacchetto OC non valido")

    manifest_files = document.get("files") or {}
    required = [document.get("model_file"), document.get("poses_file")]
    if not all(isinstance(name, str) and name for name in required):
        raise InputsMissing("Manifesto OC privo dei riferimenti a modello o pose")
    for name in required:
        stored = _file_record(raw, name)
        expected = manifest_files.get(name) if isinstance(manifest_files, dict) else None
        expected_hash = expected.get("sha256") if isinstance(expected, dict) else None
        if stored is None or not expected_hash:
            raise InputsMissing(f"Pacchetto OC incompleto: {name} assente")
        if stored.get("checksum") != expected_hash:
            raise InputsMissing(
                f"Pacchetto OC incoerente: {name} non appartiene al bundle "
                f"{document['bundle_id']}"
            )
    proxy = document.get("projection_reference") or {}
    for name in proxy.get("files", []):
        stored = _file_record(raw, name)
        expected = manifest_files.get(name) if isinstance(manifest_files, dict) else None
        expected_hash = expected.get("sha256") if isinstance(expected, dict) else None
        if stored is None or not expected_hash or stored.get("checksum") != expected_hash:
            raise InputsMissing(
                f"Riferimento di proiezione incoerente nel bundle: {name}"
            )
    return document


def _projection_mesh(result: dict) -> tuple[Optional[str], str]:
    """Preferisce la revisione clean, altrimenti usa la prima mesh raw OC."""
    clean_path = _mesh_obj_path(_mesh_entry(result, "clean"))
    if clean_path:
        return clean_path, "clean"
    return _mesh_obj_path(_mesh_entry(result, "raw")), "raw"


def _projection_reference_items(result: dict, manifest: dict | None = None) -> list[dict]:
    raw = _mesh_entry(result, "raw")
    files = [item for item in raw.get("files", []) if isinstance(item, dict)]
    proxy = (manifest or {}).get("projection_reference") or {}
    wanted = {Path(name).name for name in proxy.get("files", [])}
    if wanted and wanted.issubset({Path(item.get("name", "")).name for item in files}):
        return [item for item in files if Path(item.get("name", "")).name in wanted]
    allowed = {".obj", ".mtl", ".png", ".jpg", ".jpeg"}
    return [
        item for item in files
        if Path(item.get("name", "")).suffix.lower() in allowed
        and not Path(item.get("name", "")).name.startswith("projection_proxy")
    ]


def _download_raw_reference(
    result: dict, root: Path, manifest: dict | None = None,
) -> Optional[dict[str, Path]]:
    """Scarica solo OBJ, MTL e immagini necessarie al riferimento OC."""
    raw = _mesh_entry(result, "raw")
    files = _projection_reference_items(result, manifest)
    proxy = (manifest or {}).get("projection_reference") or {}
    main_name = Path(proxy.get("model_file") or raw.get("main_obj") or "").name
    obj_item = next((item for item in files
                     if Path(item.get("name", "")).name == main_name
                     and Path(main_name).suffix.lower() == ".obj"), None)
    if obj_item is None:
        obj_item = next((item for item in files
                         if Path(item.get("name", "")).suffix.lower() == ".obj"), None)
    mtl_items = [item for item in files
                 if Path(item.get("name", "")).suffix.lower() == ".mtl"]
    if not obj_item or not mtl_items:
        return None

    raw_dir = root / "raw_reference"
    raw_dir.mkdir()
    obj = raw_dir / Path(obj_item["name"]).name
    obj.write_bytes(storage_service.download_bytes(obj_item["path"]))
    referenced_mtl = None
    for line in obj.read_text(errors="ignore").splitlines():
        if line.lower().startswith("mtllib "):
            referenced_mtl = Path(line.split(maxsplit=1)[1].strip()).name
            break
    mtl_item = next((item for item in mtl_items
                     if Path(item.get("name", "")).name == referenced_mtl), mtl_items[0])
    mtl = raw_dir / Path(mtl_item["name"]).name
    mtl.write_bytes(storage_service.download_bytes(mtl_item["path"]))

    image_suffixes = {".png", ".jpg", ".jpeg"}
    for item in files:
        name = Path(item.get("name", "")).name
        if Path(name).suffix.lower() in image_suffixes:
            (raw_dir / name).write_bytes(storage_service.download_bytes(item["path"]))

    # L'upload appiattisce i path alla basename. Normalizziamo map_Kd allo stesso
    # modo, così funzionano anche OBJ esportati con una sottocartella textures/.
    normalized = []
    for line in mtl.read_text(errors="ignore").splitlines():
        if line.strip().lower().startswith("map_kd "):
            line = f"map_Kd {Path(line.split()[-1]).name}"
        normalized.append(line)
    mtl.write_text("\n".join(normalized) + "\n")
    return {"obj": obj, "mtl": mtl}


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

    # 2) MESH — revisione pulita se disponibile, altrimenti OBJ raw del worker.
    obj_path, mesh_kind = _projection_mesh(result)
    if obj_path:
        size = storage_service.head_size(obj_path)
        if size is not None:
            add("mesh", True, f"OBJ {mesh_kind} ({size} B)", [obj_path])
        else:
            add("mesh", False, f"manifest presente ma {obj_path} non su storage", [obj_path])
    else:
        add("mesh", False, "nessuna mesh OBJ raw o clean disponibile")

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

    try:
        bundle = validate_oc_bundle(result)
        add("oc_bundle", True, f"mesh+pose bundle {bundle['bundle_id']}")
    except InputsMissing as exc:
        add("oc_bundle", False, str(exc))

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
    manifest = validate_oc_bundle(result)
    mesh_path, mesh_kind = _projection_mesh(result)
    poses_path = _file_in(_mesh_entry(result, "raw"), "oc_poses.json")
    planes_path = (result.get("planes") or {}).get("path")
    photos = session_store.list_photos(session_id)
    missing = []
    if not mesh_path:
        missing.append("mesh")
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
    photo_paths: dict[str, str] = {}
    for photo in photos:
        index = int(photo["order_index"])
        photo_paths[str(index)] = photo["storage_path"]
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
    try:
        raw_reference = _download_raw_reference(result, root, manifest)
    except Exception:
        raw_reference = None
    return {"mesh": mesh, "mesh_kind": mesh_kind,
            "poses": poses, "planes": planes,
            "raw_reference": raw_reference,
            "photos": photos_dir, "photo_paths": photo_paths,
            "photo_count": len(photos)}


def _set_job(session_id: str, state: str, progress: float,
             message: str, error: str = "") -> None:
    sess = session_store.get_session(session_id)
    if sess is None:
        return
    result = sess.get("result") or {}
    previous = result.get("projection_job") or {}
    now = _now_iso()
    started_at = previous.get("started_at")
    if state == "queued" or not started_at:
        started_at = now
    job_id = str(uuid.uuid4()) if state == "queued" else previous.get("job_id")
    result["projection_job"] = {
        "job_id": job_id,
        "state": state,
        "progress": min(max(float(progress), 0.0), 1.0),
        "message": message,
        "error": error,
        "started_at": started_at,
        "updated_at": now,
    }
    session_store.update_session(session_id, {"result": result})


def _worker_file(
    name: str, path: str, size: int | None = None, checksum: str | None = None,
) -> dict:
    record = {
        "name": Path(name).name,
        "url": storage_service.signed_url(path, expires_in_sec=12 * 60 * 60),
        "size_bytes": size,
    }
    if checksum:
        record["sha256"] = checksum
    return record


def _worker_payload(sess: dict) -> dict:
    """Costruisce input firmati; Railway non materializza gli asset pesanti."""
    session_id = sess["id"]
    result = sess.get("result") or {}
    manifest = validate_oc_bundle(result)
    mesh_path, _ = _projection_mesh(result)
    poses_path = _file_in(_mesh_entry(result, "raw"), "oc_poses.json")
    planes_path = (result.get("planes") or {}).get("path")
    if not mesh_path or not poses_path or not planes_path:
        raise InputsMissing("Input del worker Mac incompleti")

    raw_files = []
    for item in _projection_reference_items(result, manifest):
        name = Path(item.get("name", "")).name
        path = item.get("path")
        if path:
            raw_files.append(_worker_file(
                name, path, item.get("size"), item.get("checksum"),
            ))

    photos = []
    for photo in session_store.list_photos(session_id):
        metadata = photo.get("metadata") or {}
        if isinstance(metadata, str):
            try:
                metadata = json.loads(metadata)
            except ValueError:
                metadata = {}
        photos.append({
            "order_index": int(photo["order_index"]),
            "url": storage_service.signed_url(
                photo["storage_path"], expires_in_sec=12 * 60 * 60),
            "image_width": metadata.get("image_width"),
            "image_height": metadata.get("image_height"),
        })

    job = (result.get("projection_job") or {})
    reference_hash = next(
        (item.get("sha256", "")[:16] for item in raw_files
         if item["name"].endswith(".obj")),
        "",
    )
    return {
        "session_id": session_id,
        "job_id": job.get("job_id"),
        "mesh": _worker_file("mesh.obj", mesh_path),
        "poses": _worker_file("oc_poses.json", poses_path),
        "planes": _worker_file("planes.json", planes_path),
        "raw_reference": raw_files,
        "reference_cache_key": f"{manifest.get('bundle_id', session_id)}-{reference_hash}",
        "reference_kind": (
            "projection_proxy" if manifest.get("projection_reference") else "raw"
        ),
        "photos": photos,
        "config": {
            "texel_mm": float(os.environ.get("ACRO_PROJECTION_TEXEL_MM", "20")),
            "target_long_edge_px": int(os.environ.get(
                "ACRO_PROJECTION_TARGET_LONG_EDGE_PX", "0")),
            "target_height_px": int(os.environ.get(
                "ACRO_PROJECTION_TARGET_HEIGHT_PX", "3000")),
            "max_photos": int(os.environ.get("ACRO_PROJECTION_REGISTER_PHOTOS", "12")),
            "registration_ceiling": int(os.environ.get(
                "ACRO_PROJECTION_MAX_REGISTER_PHOTOS", "12")),
            "coverage_photos": int(os.environ.get(
                "ACRO_PROJECTION_COVERAGE_PHOTOS", "24")),
            "oc_reference_bake": os.environ.get(
                "ACRO_OC_REFERENCE_BAKE", "1") not in {"0", "false", "False"},
            "default_scale": float(os.environ.get("ACRO_OC_SCALE", "6.0927")),
        },
    }


def claim_next_worker_job() -> dict:
    """Reclama il prossimo bake remoto e restituisce i soli URL firmati."""
    now = _now_iso()
    sess = session_store.claim_next_projection_job({
        "state": "running",
        "progress": 0.02,
        "message": "Worker Mac: preparo gli input",
        "error": "",
        "updated_at": now,
    })
    if sess is None:
        return {}
    session_id = sess["id"]
    current = sess.get("status") or ""
    if current in {session_state.PLANES_READY, session_state.COMPLETED}:
        try:
            session_store.update_status(session_id, session_state.MAPPING)
        except ValueError:
            pass
    latest = session_store.get_session(session_id) or sess
    try:
        return _worker_payload(latest)
    except Exception as exc:
        _set_job(session_id, "failed", 1.0, "Input worker Mac non validi", str(exc)[:500])
        raise


def update_worker_progress(
    session_id: str, job_id: str, progress: float, message: str,
) -> None:
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")
    current = ((sess.get("result") or {}).get("projection_job") or {})
    if current.get("job_id") != job_id or current.get("state") != "running":
        raise ProjectionError("Job di proiezione non piu' corrente")
    _set_job(session_id, "running", progress, message)


def complete_worker_job(
    session_id: str, job_id: str, manifest: dict, files: list[dict],
) -> dict:
    """Pubblica atomicamente il manifesto solo se mesh/piani non sono cambiati."""
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")
    result = sess.get("result") or {}
    current = result.get("projection_job") or {}
    if current.get("job_id") != job_id or current.get("state") != "running":
        raise ProjectionError("Risultato obsoleto: mesh o piani sono stati modificati")
    names = {item.get("name") for item in files}
    main_obj = Path(str(manifest.get("main_obj") or "")).name
    if not main_obj or main_obj not in names:
        raise ProjectionError("Bundle del worker privo dell'OBJ principale")
    projection = {
        "main_obj": main_obj,
        "files": files,
        "planes": manifest.get("planes") or [],
        "total_area_m2": float(manifest.get("total_area_m2", 0.0)),
        "coverage": float(manifest.get("coverage", 0.0)),
        "photo_count": int(manifest.get("photo_count", 0)),
        "scale_m_per_mesh_unit": float(manifest.get("scale_m_per_mesh_unit", 1.0)),
        "projection_mode": manifest.get("projection_mode", "pose_only"),
        "texture_encoding": manifest.get("texture_encoding", "sRGB"),
        "fallback_reason": manifest.get("fallback_reason", ""),
    }
    result["projection"] = projection
    result.pop("metric_openings", None)
    result.pop("opening_detection_job", None)
    session_store.update_session(session_id, {"result": result})
    try:
        session_store.update_status(session_id, session_state.COMPLETED)
    except Exception:
        pass
    _set_job(session_id, "complete", 1.0, "Texture pronta")
    return _public_result(session_store.get_session(session_id) or sess)


def fail_worker_job(session_id: str, job_id: str, error: str) -> None:
    sess = session_store.get_session(session_id)
    if sess is None:
        return
    current = ((sess.get("result") or {}).get("projection_job") or {})
    if current.get("job_id") == job_id:
        _set_job(session_id, "failed", 1.0, "Proiezione non riuscita", error[:500])


def _public_result(sess: dict) -> dict:
    result = sess.get("result") or {}
    job = result.get("projection_job") or {}
    manifest = result.get("projection") or {}
    public_files = [
        {
            "name": f["name"],
            "url": storage_service.signed_url(f["path"], expires_in_sec=3600),
            "size_bytes": f["size"],
            "checksum": f.get("checksum"),
        }
        for f in manifest.get("files", [])
    ]
    main_name = manifest.get("main_obj")
    main = next((f for f in public_files if f["name"] == main_name), None)
    return {
        "state": job.get("state", "complete" if main else "idle"),
        "progress": float(job.get("progress", 1.0 if main else 0.0)),
        "message": job.get("message", "Texture pronta" if main else "Non avviata"),
        "error": job.get("error", ""),
        "status": sess.get("status") or "",
        "count": len(manifest.get("planes", [])),
        "total_area_m2": float(manifest.get("total_area_m2", 0.0)),
        "coverage": float(manifest.get("coverage", 0.0)),
        "main_obj": main,
        "files": public_files,
        "planes": manifest.get("planes", []),
        "projection_mode": manifest.get("projection_mode", ""),
        "texture_encoding": manifest.get("texture_encoding", ""),
        "fallback_reason": manifest.get("fallback_reason", ""),
    }


def start_project(session_id: str) -> tuple[dict, bool]:
    """Valida gli input e marca il job come accodato. Ritorna anche se avviarlo."""
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")
    job = ((sess.get("result") or {}).get("projection_job") or {})
    if job.get("state") in _ACTIVE_JOB_STATES:
        if not _job_is_stale(job):
            return _public_result(sess), False
        _set_job(
            session_id, "failed", 1.0, "Proiezione interrotta",
            "Il processo precedente non e piu attivo; avvia nuovamente la proiezione.",
        )
        sess = session_store.get_session(session_id) or sess
    report = gather_inputs(session_id)
    if not report or not report["ready"]:
        raise InputsMissing("Input mancanti per la proiezione: " +
                            ", ".join((report or {}).get("missing", [])))
    _set_job(session_id, "queued", 0.0, "Proiezione accodata")
    return _public_result(session_store.get_session(session_id) or sess), True


def project_status(session_id: str) -> Optional[dict]:
    sess = session_store.get_session(session_id)
    if sess is not None:
        job = ((sess.get("result") or {}).get("projection_job") or {})
        if _job_is_stale(job):
            _set_job(
                session_id, "failed", 1.0, "Proiezione interrotta",
                "Il server e stato riavviato durante il calcolo; rilancia la proiezione.",
            )
            sess = session_store.get_session(session_id) or sess
    return _public_result(sess) if sess is not None else None


def run_project_job(session_id: str) -> None:
    """Entry point del BackgroundTask: registra sempre completamento o errore."""
    try:
        project(session_id)
    except Exception as exc:
        _set_job(session_id, "failed", 1.0, "Proiezione non riuscita", str(exc)[:500])


def project(session_id: str) -> dict:
    """Esegue il mosaico e pubblica il bundle texturizzato dei piani."""
    sess = session_store.get_session(session_id)
    if sess is None:
        raise InputsMissing("Sessione non trovata")

    try:
        _set_job(session_id, "running", 0.02, "Preparo gli input")
        current = sess.get("status") or ""
        if current in {session_state.PLANES_READY, session_state.COMPLETED}:
            session_store.update_status(session_id, session_state.MAPPING)

        with tempfile.TemporaryDirectory(prefix="acro_projection_") as td:
            root = Path(td)
            inp = _download_inputs(session_id, sess, root)
            from .plane_geometry import regularize_planes_document
            inp["planes"] = regularize_planes_document(inp["planes"])
            out_dir = root / "output"
            scale = float(inp["planes"].get(
                "scale_m_per_mesh_unit",
                os.environ.get("ACRO_OC_SCALE", "6.0927"),
            ))
            downloaded = [0]

            def resolve_photo(key: str) -> str | None:
                remote = inp["photo_paths"].get(str(int(key)))
                if not remote:
                    return None
                local = inp["photos"] / f"{int(key):04d}.jpg"
                if not local.exists():
                    local.write_bytes(storage_service.download_bytes(remote))
                    downloaded[0] += 1
                    _set_job(
                        session_id, "running", 0.12,
                        f"Scarico foto selezionate: {downloaded[0]}")
                return str(local)

            texel_mm = float(os.environ.get("ACRO_PROJECTION_TEXEL_MM", "20"))
            target_long_edge_px = int(os.environ.get(
                "ACRO_PROJECTION_TARGET_LONG_EDGE_PX", "0"))
            target_height_px = int(os.environ.get(
                "ACRO_PROJECTION_TARGET_HEIGHT_PX", "3000"))
            max_photos = int(os.environ.get("ACRO_PROJECTION_REGISTER_PHOTOS", "12"))
            registration_ceiling = int(os.environ.get(
                "ACRO_PROJECTION_MAX_REGISTER_PHOTOS", "12"))
            coverage_photos = int(os.environ.get("ACRO_PROJECTION_COVERAGE_PHOTOS", "24"))
            fallback_reason = ""
            raw_reference = inp.get("raw_reference")
            enhanced = bool(raw_reference) and os.environ.get(
                "ACRO_OC_REFERENCE_BAKE", "1") not in {"0", "false", "False"}
            if enhanced:
                try:
                    from . import oc_reference_bake

                    _set_job(session_id, "running", 0.14,
                             "Allineo le foto al riferimento Object Capture")
                    summary = oc_reference_bake.bake_planes(
                        str(inp["mesh"]), str(raw_reference["obj"]),
                        str(raw_reference["mtl"]), inp["poses"],
                        str(inp["photos"]), inp["planes"], str(out_dir),
                        texel_mm=texel_mm, max_photos=max_photos,
                        target_long_edge_px=target_long_edge_px,
                        target_height_px=target_height_px,
                        registration_ceiling=registration_ceiling,
                        coverage_photos=coverage_photos, crop=0.9,
                        scale_m_per_mesh_unit=scale,
                        photo_resolver=resolve_photo,
                        progress=lambda done, total, name: _set_job(
                            session_id, "running", 0.15 + 0.65 * done / max(total, 1),
                            f"Registro piano {done}/{total}: {name}"),
                    )
                except Exception as exc:
                    fallback_reason = str(exc)[:300]
                    shutil.rmtree(out_dir, ignore_errors=True)
                    _set_job(session_id, "running", 0.14,
                             "Riferimento OC non utilizzabile, applico le pose")
                    summary = ortho_bake.bake_planes(
                        str(inp["mesh"]), inp["poses"], str(inp["photos"]),
                        inp["planes"], str(out_dir), texel_mm=texel_mm,
                        target_long_edge_px=target_long_edge_px,
                        target_height_px=target_height_px,
                        max_photos=max_photos, occlusion=False, facing_min=0.342,
                        crop=0.9, scale_m_per_mesh_unit=scale,
                        photo_resolver=resolve_photo,
                        available_photo_keys=set(inp["photo_paths"]),
                        progress=lambda done, total, name: _set_job(
                            session_id, "running", 0.15 + 0.65 * done / max(total, 1),
                            f"Proietto piano {done}/{total}: {name}"),
                    )
                    summary["projection_mode"] = "pose_only_fallback"
            else:
                fallback_reason = "mesh OC testurizzata non disponibile"
                summary = ortho_bake.bake_planes(
                    str(inp["mesh"]), inp["poses"], str(inp["photos"]),
                    inp["planes"], str(out_dir), texel_mm=texel_mm,
                    target_long_edge_px=target_long_edge_px,
                    target_height_px=target_height_px,
                    max_photos=max_photos, occlusion=False, facing_min=0.342,
                    crop=0.9, scale_m_per_mesh_unit=scale,
                    photo_resolver=resolve_photo,
                    available_photo_keys=set(inp["photo_paths"]),
                    progress=lambda done, total, name: _set_job(
                        session_id, "running", 0.15 + 0.65 * done / max(total, 1),
                        f"Proietto piano {done}/{total}: {name}"),
                )
                summary["projection_mode"] = "pose_only_fallback"
            if summary["count"] == 0:
                raise ProjectionError("Nessun piano ha prodotto una texture")

            files = []
            output_files = [p for p in sorted(out_dir.iterdir()) if p.is_file()]
            for file_index, local in enumerate(output_files, 1):
                if not local.is_file():
                    continue
                data = local.read_bytes()
                remote = storage_service.out_path(
                    session_id, f"projection/{local.name}")
                storage_service.upload_bytes(
                    remote, data,
                    _CONTENT_TYPES.get(local.suffix.lower(), "application/octet-stream"),
                )
                files.append({"name": local.name, "path": remote,
                              "size": len(data),
                              "checksum": hashlib.sha256(data).hexdigest()})
                _set_job(
                    session_id, "running",
                    0.80 + 0.18 * file_index / max(len(output_files), 1),
                    f"Carico risultato {file_index}/{len(output_files)}")

            manifest = {
                "main_obj": summary["main_obj"],
                "files": files,
                "planes": summary["planes"],
                "total_area_m2": summary["total_area_m2"],
                "coverage": summary["coverage"],
                "photo_count": inp["photo_count"],
                "scale_m_per_mesh_unit": scale,
                "projection_mode": summary.get("projection_mode", "pose_only"),
                "texture_encoding": summary.get("texture_encoding", "sRGB"),
                "fallback_reason": fallback_reason,
            }
            latest = session_store.get_session(session_id) or sess
            result = latest.get("result") or {}
            result["projection"] = manifest
            # Le aperture sono derivate pixel-per-pixel da queste texture. Un
            # nuovo bake invalida sempre geometria UV e computo precedenti.
            result.pop("metric_openings", None)
            result.pop("opening_detection_job", None)
            session_store.update_session(session_id, {"result": result})

        try:
            session_store.update_status(session_id, session_state.COMPLETED)
        except Exception:
            pass

        _set_job(session_id, "complete", 1.0, "Texture pronta")
        return _public_result(session_store.get_session(session_id) or sess)
    except (InputsMissing, ProjectionError):
        raise
    except Exception as exc:
        raise ProjectionError(f"Proiezione non riuscita: {exc}") from exc
