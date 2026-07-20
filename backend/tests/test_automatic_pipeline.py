from app.models import DetectedPlane, DetectPlanesResult
from app.routers import facade_sessions


def _detected() -> DetectPlanesResult:
    return DetectPlanesResult(
        session_id="session-1",
        up=[0.0, 1.0, 0.0],
        count=1,
        engine="fused",
        planes=[DetectedPlane(
            nome="Facciata 1",
            tipo="facciata",
            punto=[0.0, 0.0, 0.0],
            normale=[0.0, 0.0, 1.0],
            corners=[
                [0.0, 0.0, 0.0], [1.0, 0.0, 0.0],
                [1.0, 1.0, 0.0], [0.0, 1.0, 0.0],
            ],
            area_m2=1.0,
            w=1.0,
            h=1.0,
            triangoli=[0, 1],
        )],
    )


def test_automatic_pipeline_detects_saves_then_projects(monkeypatch):
    calls = []
    jobs = []
    monkeypatch.setattr(
        facade_sessions, "detect_planes",
        lambda session_id, payload: calls.append(("detect", payload)) or _detected(),
    )
    monkeypatch.setattr(
        facade_sessions, "save_planes",
        lambda session_id, payload: calls.append(("save", payload)),
    )
    monkeypatch.setattr(
        facade_sessions.projection_service, "project",
        lambda session_id: calls.append(("project", session_id)),
    )
    monkeypatch.setattr(
        facade_sessions.projection_service, "_set_job",
        lambda *args: jobs.append(args),
    )

    facade_sessions._run_automatic_mesh_pipeline("session-1")

    assert [item[0] for item in calls] == ["detect", "save", "project"]
    payload = calls[1][1]
    assert payload["schema"] == "acro.planes/v1"
    assert payload["piano_base"]["up"] == [0.0, 1.0, 0.0]
    assert payload["planes"][0]["triangoli"] == [0, 1]
    assert calls[0][1]["mesh_kind"] == "raw"
    assert jobs[0][1:4] == ("running", 0.02, "Riconosco i piani della facciata")


def test_detection_source_is_explicit_and_never_falls_back():
    result = {"mesh": {
        "raw": {
            "main_obj": "raw.obj",
            "files": [{"name": "raw.obj", "path": "raw/raw.obj"}],
        },
        "clean": {
            "main_obj": "clean.obj",
            "files": [{"name": "clean.obj", "path": "clean/clean.obj"}],
        },
    }}

    assert facade_sessions._mesh_obj_for_detection(result) == \
        ("clean/clean.obj", "clean")
    assert facade_sessions._mesh_obj_for_detection(result, "raw") == \
        ("raw/raw.obj", "raw")
    assert facade_sessions._mesh_obj_for_detection(
        {"mesh": {"clean": result["mesh"]["clean"]}}, "raw",
    ) == (None, "raw")


def test_reset_derived_keeps_only_raw_mesh(monkeypatch):
    result = {"mesh": {
        "raw": {
            "main_obj": "raw.obj",
            "files": [{"name": "raw.obj", "path": "raw/raw.obj"}],
        },
        "clean": {
            "main_obj": "clean.obj",
            "files": [{"name": "clean.obj", "path": "clean/clean.obj"}],
        },
    }, "planes": {"path": "out/planes.json"}, "projection": {
        "files": [{"name": "planes.obj", "path": "projection/planes.obj"}],
    }, "metric_openings": {"openings": []}, "zone_markup": {
        "storage_path": "out/zone_markup.json",
    }}
    session = {"id": "session-1", "status": "completed", "result": result}
    updates = []
    deleted = []
    monkeypatch.setattr(
        facade_sessions.session_store, "get_session", lambda session_id: session)
    monkeypatch.setattr(
        facade_sessions.session_store, "update_session",
        lambda session_id, fields: updates.append(fields) or fields)
    monkeypatch.setattr(
        facade_sessions.storage_service, "delete_paths",
        lambda paths: deleted.extend(paths) or len(paths))

    response = facade_sessions.reset_derived("session-1")

    assert response.status == "mesh_ready"
    assert response.deleted_files == 4
    assert set(deleted) == {
        "clean/clean.obj", "out/planes.json", "projection/planes.obj",
        "out/zone_markup.json",
    }
    saved = updates[0]
    assert saved["status"] == "mesh_ready"
    assert set(saved["result"]["mesh"]) == {"raw"}
    assert "planes" not in saved["result"]
    assert "projection" not in saved["result"]
    assert "metric_openings" not in saved["result"]
    assert "zone_markup" not in saved["result"]


def test_automatic_pipeline_exposes_failure_in_projection_job(monkeypatch):
    jobs = []
    monkeypatch.setattr(
        facade_sessions, "detect_planes",
        lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError("detector offline")),
    )
    monkeypatch.setattr(
        facade_sessions.projection_service, "_set_job",
        lambda *args: jobs.append(args),
    )

    facade_sessions._run_automatic_mesh_pipeline("session-1")

    assert jobs[-1][1] == "failed"
    assert "detector offline" in jobs[-1][-1]


def test_mesh_ready_waits_for_clean_geometry(monkeypatch):
    session = {
        "id": "session-1",
        "status": "computing_oc",
        "created_at": "2026-07-19T20:00:00+00:00",
        "updated_at": "2026-07-19T20:00:00+00:00",
        "result": None,
    }
    jobs = []
    monkeypatch.setattr(
        facade_sessions.session_store, "get_session", lambda session_id: session,
    )
    monkeypatch.setattr(
        facade_sessions.session_store, "update_status",
        lambda session_id, status: {**session, "status": status},
    )
    monkeypatch.setattr(
        facade_sessions.session_store, "list_photos", lambda session_id: [],
    )
    monkeypatch.setattr(
        facade_sessions.projection_service, "_set_job",
        lambda *args: jobs.append(args),
    )

    result = facade_sessions.mesh_ready("session-1")

    assert result.status == "mesh_ready"
    assert jobs == [(
        "session-1", "idle", 0.0,
        "Mesh OC originale pronta: attendo la pulizia",
    )]


def test_plane_edits_preserve_the_first_texture_frame():
    original = {
        "planes": [{
            "id": 4, "nome": "Facciata",
            "normale": [0, 0, 1], "punto": [0, 0, 0],
            "corners": [[0, 0, 0], [1, 0, 0], [1, 1, 0]],
        }],
    }
    first_save = facade_sessions._preserve_texture_frames(original)
    edited = {
        "planes": [{
            "id": 4, "nome": "Facciata",
            "normale": [0.1, 0, 0.99], "punto": [0, 0, 0.2],
            "corners": [[0, 0, 0.2], [2, 0, 0.2], [2, 1, 0.2]],
        }],
    }

    second_save = facade_sessions._preserve_texture_frames(edited, first_save)

    assert second_save["planes"][0]["normale"] == [0.1, 0, 0.99]
    assert second_save["planes"][0]["texture_frame"] == {
        "normale": [0, 0, 1],
        "punto": [0, 0, 0],
        "corners": [[0, 0, 0], [1, 0, 0], [1, 1, 0]],
    }


def test_texture_frames_follow_stable_names_when_local_ids_shift():
    previous = {
        "planes": [
            {
                "id": 2, "nome": "Facciata - seg 1",
                "normale": [0, 0, 1], "punto": [0, 0, 0],
                "corners": [[0, 0, 0], [1, 0, 0], [1, 1, 0]],
                "texture_frame": {
                    "marker": "facade", "normale": [0, 0, 1],
                    "punto": [0, 0, 0], "corners": [],
                },
            },
            {
                "id": 3, "nome": "Spalletta - seg 2",
                "normale": [1, 0, 0], "punto": [1, 0, 0],
                "corners": [[1, 0, 0], [1, 0, 1], [1, 1, 1]],
                "texture_frame": {
                    "marker": "reveal", "normale": [1, 0, 0],
                    "punto": [1, 0, 0], "corners": [],
                },
            },
        ],
    }
    reloaded = {
        "planes": [
            {
                "id": 1, "nome": "Facciata - seg 1",
                "normale": [0, 0, 1], "punto": [0, 0, 0],
                "corners": [[0, 0, 0], [1, 0, 0], [1, 1, 0]],
            },
            {
                "id": 2, "nome": "Spalletta - seg 2",
                "normale": [1, 0, 0], "punto": [1, 0, 0],
                "corners": [[1, 0, 0], [1, 0, 1], [1, 1, 1]],
            },
        ],
    }

    result = facade_sessions._preserve_texture_frames(reloaded, previous)

    assert result["planes"][0]["texture_frame"]["marker"] == "facade"
    assert result["planes"][1]["texture_frame"]["marker"] == "reveal"


def test_invalid_perpendicular_stored_frame_uses_valid_incoming_repair():
    previous = {
        "planes": [{
            "id": 1, "nome": "Spalletta - seg 2",
            "normale": [1, 0, 0], "punto": [1, 0, 0],
            "corners": [[1, 0, 0], [1, 0, 1], [1, 1, 1]],
            "texture_frame": {
                "normale": [0, 0, 1], "punto": [0, 0, 0],
                "corners": [[0, 0, 0], [1, 0, 0], [1, 1, 0]],
            },
        }],
    }
    repair = {
        "normale": [1, 0, 0], "punto": [1, 0, 0],
        "corners": [[1, 0, 0], [1, 0, 1], [1, 1, 1]],
    }
    payload = {
        "planes": [{
            "id": 1, "nome": "Spalletta - seg 2",
            "normale": [1, 0, 0], "punto": [1, 0, 0],
            "corners": [[1, 0, 0], [1, 0, 1], [1, 1, 1]],
            "texture_frame": repair,
        }],
    }

    result = facade_sessions._preserve_texture_frames(payload, previous)

    assert result["planes"][0]["texture_frame"] == repair
