from pathlib import Path

from fastapi import HTTPException

from app.models import DirectUploadRecord
from app.routers import facade_sessions


def test_direct_record_requires_canonical_path(monkeypatch):
    monkeypatch.setattr(
        facade_sessions.storage_service,
        "head_object",
        lambda _path: {"size": 12, "content_type": "model/obj", "etag": "x"},
    )
    record = DirectUploadRecord(
        name="mesh.obj", path="sessions/other/mesh.obj", size_bytes=12)

    try:
        facade_sessions._verify_direct_record(
            record, "sessions/current/mesh.obj")
    except HTTPException as exc:
        assert exc.status_code == 400
    else:
        raise AssertionError("Un path di un'altra sessione doveva essere rifiutato")


def test_direct_record_rejects_partial_upload(monkeypatch):
    monkeypatch.setattr(
        facade_sessions.storage_service,
        "head_object",
        lambda _path: {"size": 11, "content_type": "model/obj", "etag": "x"},
    )
    record = DirectUploadRecord(
        name="mesh.obj", path="sessions/current/mesh.obj", size_bytes=12)

    try:
        facade_sessions._verify_direct_record(
            record, "sessions/current/mesh.obj")
    except HTTPException as exc:
        assert exc.status_code == 409
        assert "incompleto" in str(exc.detail)
    else:
        raise AssertionError("Un upload parziale doveva essere rifiutato")


def test_worker_streams_direct_file_and_returns_commit_record(
    monkeypatch, tmp_path,
):
    from importlib.util import module_from_spec, spec_from_file_location

    module_path = (
        Path(__file__).parents[1]
        / "photogrammetry" / "objectcapture" / "oc_worker.py"
    )
    spec = spec_from_file_location("oc_worker_direct", module_path)
    worker = module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(worker)

    source = tmp_path / "mesh.obj"
    source.write_bytes(b"v 0 0 0\n")
    calls = []

    class Response:
        def raise_for_status(self):
            return None

    def put(url, data, headers, timeout):
        calls.append((url, data.read(), headers, timeout))
        return Response()

    monkeypatch.setattr(worker.requests, "put", put)
    records = worker.Client._put_direct_files([{
        "name": "mesh.obj",
        "path": "sessions/s/out/mesh/raw/mesh.obj",
        "url": "https://r2.test/upload",
        "headers": {"Content-Type": "model/obj"},
    }], [("mesh.obj", source)])

    assert calls[0][1] == b"v 0 0 0\n"
    assert records[0]["size_bytes"] == source.stat().st_size
    assert records[0]["path"].endswith("mesh.obj")
    assert len(records[0]["checksum"]) == 64
