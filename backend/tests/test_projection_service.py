from app.services import projection_service


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
