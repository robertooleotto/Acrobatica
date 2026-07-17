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
    assert jobs[0][1:4] == ("running", 0.02, "Riconosco i piani della facciata")


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
