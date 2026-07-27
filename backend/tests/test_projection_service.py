from datetime import datetime, timedelta, timezone
import json

from app.services import projection_service


def _raw_bundle(checksum_model="model-hash", checksum_poses="poses-hash"):
    document = {
        "schema": "acro.oc-bundle/v1",
        "bundle_id": "bundle-1",
        "model_file": "model.obj",
        "poses_file": "oc_poses.json",
        "files": {
            "model.obj": {"sha256": "model-hash"},
            "oc_poses.json": {"sha256": "poses-hash"},
        },
    }
    result = {"mesh": {"raw": {"files": [
        {"name": "model.obj", "path": "raw/model.obj", "checksum": checksum_model},
        {"name": "oc_poses.json", "path": "raw/oc_poses.json", "checksum": checksum_poses},
        {"name": "oc_bundle_manifest.json", "path": "raw/manifest.json", "checksum": "manifest-hash"},
    ]}}}
    return result, json.dumps(document).encode()


def test_oc_bundle_accepts_model_and_poses_from_same_job(monkeypatch):
    result, manifest = _raw_bundle()
    monkeypatch.setattr(
        projection_service.storage_service, "download_bytes",
        lambda path: manifest,
    )

    document = projection_service.validate_oc_bundle(result)

    assert document["bundle_id"] == "bundle-1"


def test_oc_bundle_rejects_poses_replaced_from_another_job(monkeypatch):
    result, manifest = _raw_bundle(checksum_poses="different-pose-hash")
    monkeypatch.setattr(
        projection_service.storage_service, "download_bytes",
        lambda path: manifest,
    )

    try:
        projection_service.validate_oc_bundle(result)
    except projection_service.InputsMissing as exc:
        assert "oc_poses.json non appartiene" in str(exc)
    else:
        raise AssertionError("Il bundle incoerente doveva essere rifiutato")


def test_download_raw_reference_rebuilds_flattened_texture_paths(monkeypatch, tmp_path):
    payloads = {
        "raw/model.obj": b"mtllib materials/model.mtl\nv 0 0 0\n",
        "raw/model.mtl": b"newmtl oc\nmap_Kd textures/albedo.png\n",
        "raw/albedo.png": b"png-data",
    }
    monkeypatch.setattr(
        projection_service.storage_service, "download_bytes",
        lambda path: payloads[path],
    )
    result = {
        "mesh": {"raw": {"files": [
            {"name": "model.obj", "path": "raw/model.obj"},
            {"name": "model.mtl", "path": "raw/model.mtl"},
            {"name": "albedo.png", "path": "raw/albedo.png"},
        ]}},
    }

    reference = projection_service._download_raw_reference(result, tmp_path)

    assert reference is not None
    assert reference["obj"].name == "model.obj"
    assert reference["mtl"].read_text().endswith("map_Kd albedo.png\n")
    assert (reference["mtl"].parent / "albedo.png").read_bytes() == b"png-data"


def test_active_job_without_heartbeat_is_stale():
    assert projection_service._job_is_stale({"state": "running"})


def test_recent_job_heartbeat_is_not_stale():
    now = datetime.now(timezone.utc)
    job = {"state": "running", "updated_at": (now - timedelta(seconds=30)).isoformat()}

    assert not projection_service._job_is_stale(job, now=now)


def test_geometry_change_invalidates_derived_outputs_and_optionally_planes():
    result = {
        "mesh": {"clean": {"files": ["mesh.obj"]}},
        "planes": {"path": "planes.json"},
        "projection": {"main_obj": "planes.obj"},
        "projection_job": {"state": "complete"},
        "metric_openings": {"openings": [{"id": "window-1"}]},
        "opening_detection_job": {"state": "complete"},
    }

    projection_service.invalidate_geometry_outputs(result)
    assert "mesh" in result
    assert "planes" in result
    assert "projection" not in result
    assert "projection_job" not in result
    assert "metric_openings" not in result
    assert "opening_detection_job" not in result

    projection_service.invalidate_geometry_outputs(result, clear_planes=True)
    assert "planes" not in result


def test_projection_prefers_clean_obj_and_falls_back_to_raw_obj():
    raw_only = {
        "mesh": {"raw": {
            "main_obj": "model.usdz",
            "files": [
                {"name": "model.usdz", "path": "raw/model.usdz"},
                {"name": "model.obj", "path": "raw/model.obj"},
            ],
        }},
    }
    assert projection_service._projection_mesh(raw_only) == ("raw/model.obj", "raw")

    with_clean = {
        **raw_only,
        "mesh": {
            **raw_only["mesh"],
            "clean": {
                "main_obj": "clean.obj",
                "files": [{"name": "clean.obj", "path": "clean/clean.obj"}],
            },
        },
    }
    assert projection_service._projection_mesh(with_clean) == \
        ("clean/clean.obj", "clean")


def test_public_projection_files_include_stable_checksum(monkeypatch):
    monkeypatch.setattr(
        projection_service.storage_service, "signed_url",
        lambda path, expires_in_sec: f"https://example.test/{path}",
    )
    session = {
        "status": "completed",
        "result": {
            "projection_job": {"state": "complete"},
            "projection": {
                "main_obj": "planes.obj",
                "files": [{
                    "name": "planes.obj",
                    "path": "projection/planes.obj",
                    "size": 123,
                    "checksum": "abc123",
                }],
            },
        },
    }

    result = projection_service._public_result(session)

    assert result["main_obj"]["checksum"] == "abc123"
    assert result["files"][0]["checksum"] == "abc123"


def test_projection_job_id_is_preserved_until_a_new_queue(monkeypatch):
    state = {"id": "session-1", "result": {}}
    monkeypatch.setattr(
        projection_service.session_store, "get_session", lambda _sid: state)

    def update(_sid, fields):
        state.update(fields)
        return state

    monkeypatch.setattr(projection_service.session_store, "update_session", update)

    projection_service._set_job("session-1", "queued", 0.0, "queued")
    first = state["result"]["projection_job"]["job_id"]
    projection_service._set_job("session-1", "running", 0.2, "running")
    assert state["result"]["projection_job"]["job_id"] == first

    projection_service._set_job("session-1", "queued", 0.0, "queued again")
    assert state["result"]["projection_job"]["job_id"] != first


def test_worker_payload_returns_signed_urls_without_materializing_assets(monkeypatch):
    session = {
        "id": "session-1",
        "result": {
            "projection_job": {"job_id": "job-1", "state": "running"},
            "planes": {"path": "out/planes.json"},
            "mesh": {
                "clean": {"files": [{"name": "clean.obj", "path": "clean.obj"}]},
                "raw": {"files": [
                    {"name": "model.obj", "path": "raw/model.obj"},
                    {"name": "model.mtl", "path": "raw/model.mtl"},
                    {"name": "albedo.png", "path": "raw/albedo.png"},
                    {"name": "oc_poses.json", "path": "raw/oc_poses.json"},
                ]},
            },
        },
    }
    monkeypatch.setattr(projection_service, "validate_oc_bundle", lambda _result: {})
    monkeypatch.setattr(
        projection_service.session_store, "list_photos",
        lambda _sid: [{
            "order_index": 7, "storage_path": "photos/0007.jpg",
            "metadata": {"image_width": 4032, "image_height": 3024},
        }],
    )
    monkeypatch.setattr(
        projection_service.storage_service, "signed_url",
        lambda path, expires_in_sec: f"signed://{path}",
    )

    payload = projection_service._worker_payload(session)

    assert payload["job_id"] == "job-1"
    assert payload["mesh"]["url"] == "signed://clean.obj"
    assert payload["poses"]["url"] == "signed://raw/oc_poses.json"
    assert payload["planes"]["url"] == "signed://out/planes.json"
    assert payload["photos"] == [{
        "order_index": 7,
        "url": "signed://photos/0007.jpg",
        "image_width": 4032,
        "image_height": 3024,
    }]
    assert {item["name"] for item in payload["raw_reference"]} == {
        "model.obj", "model.mtl", "albedo.png",
    }


def test_worker_result_is_rejected_after_job_invalidation(monkeypatch):
    session = {
        "id": "session-1",
        "status": "mapping",
        "result": {"projection_job": {"job_id": "new-job", "state": "running"}},
    }
    monkeypatch.setattr(
        projection_service.session_store, "get_session", lambda _sid: session)

    try:
        projection_service.complete_worker_job(
            "session-1", "old-job", {"main_obj": "planes.obj"},
            [{"name": "planes.obj", "path": "out/planes.obj", "size": 1}],
        )
    except projection_service.ProjectionError as exc:
        assert "obsoleto" in str(exc)
    else:
        raise AssertionError("Il risultato del vecchio job doveva essere rifiutato")
