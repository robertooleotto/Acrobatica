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
import shutil
import tempfile
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
_JOB_STALE_SECONDS = 15 * 60


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


def _download_raw_reference(result: dict, root: Path) -> Optional[dict[str, Path]]:
    """Scarica solo OBJ, MTL e immagini necessarie al riferimento OC."""
    raw = _mesh_entry(result, "raw")
    files = [item for item in raw.get("files", []) if isinstance(item, dict)]
    main_name = Path(raw.get("main_obj") or "").name
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
        raw_reference = _download_raw_reference(result, root)
    except Exception:
        raw_reference = None
    return {"mesh": mesh, "poses": poses, "planes": planes,
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
    result["projection_job"] = {
        "state": state,
        "progress": min(max(float(progress), 0.0), 1.0),
        "message": message,
        "error": error,
        "started_at": started_at,
        "updated_at": now,
    }
    session_store.update_session(session_id, {"result": result})


def _public_result(sess: dict) -> dict:
    result = sess.get("result") or {}
    job = result.get("projection_job") or {}
    manifest = result.get("projection") or {}
    public_files = [
        {
            "name": f["name"],
            "url": storage_service.signed_url(f["path"], expires_in_sec=3600),
            "size_bytes": f["size"],
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
            max_photos = int(os.environ.get("ACRO_PROJECTION_REGISTER_PHOTOS", "20"))
            registration_ceiling = int(os.environ.get(
                "ACRO_PROJECTION_MAX_REGISTER_PHOTOS", "80"))
            coverage_photos = int(os.environ.get("ACRO_PROJECTION_COVERAGE_PHOTOS", "100"))
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
                remote = storage_service.out_path(
                    session_id, f"projection/{local.name}")
                storage_service.upload_bytes(
                    remote, local.read_bytes(),
                    _CONTENT_TYPES.get(local.suffix.lower(), "application/octet-stream"),
                )
                files.append({"name": local.name, "path": remote,
                              "size": local.stat().st_size})
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
