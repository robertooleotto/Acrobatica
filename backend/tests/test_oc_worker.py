import importlib.util
import json
from pathlib import Path
import zipfile

import numpy as np
import pytest


MODULE_PATH = (
    Path(__file__).parents[1]
    / "photogrammetry" / "objectcapture" / "oc_worker.py"
)
SPEC = importlib.util.spec_from_file_location("oc_worker", MODULE_PATH)
oc_worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(oc_worker)


def test_cloud_worker_defaults_to_raw_nobbox_preset():
    assert oc_worker.DEFAULT_OC_DETAIL == "raw"
    assert oc_worker.OBJECT_CAPTURE_PRESET["ignore_bounding_box"] is True
    assert oc_worker.OBJECT_CAPTURE_PRESET["sample_ordering"] == "sequential"
    assert oc_worker.OBJECT_CAPTURE_PRESET["feature_sensitivity"] == "high"
    assert oc_worker.OBJECT_CAPTURE_PRESET["model_and_poses_same_session"] is True


def test_bundle_manifest_binds_model_and_poses(tmp_path):
    model = tmp_path / "model.obj"
    poses = tmp_path / "oc_poses.json"
    model.write_bytes(b"v 0 0 0\n")
    poses.write_text('{"0": {}}')

    output = tmp_path / "oc_bundle_manifest.json"
    document = oc_worker.write_bundle_manifest(
        output,
        [(model.name, str(model)), (poses.name, str(poses))],
        photo_count=1,
        detail="raw",
    )

    saved = json.loads(output.read_text())
    assert saved == document
    assert saved["schema"] == "acro.oc-bundle/v1"
    assert saved["model_file"] == "model.obj"
    assert saved["poses_file"] == "oc_poses.json"
    assert saved["files"]["model.obj"]["sha256"] == oc_worker.sha256_file(model)
    assert saved["object_capture"] == {
        **oc_worker.OBJECT_CAPTURE_PRESET,
        "detail": "raw",
    }


def _arkit_transform(center):
    matrix = np.eye(4)
    matrix[:3, 3] = center
    return matrix.flatten(order="F").tolist()


def test_metric_calibration_recovers_session_scale_and_rejects_outlier(tmp_path):
    source = np.asarray([
        [-1.2, -0.8, 0.1], [0.0, -0.8, 0.0], [1.3, -0.7, 0.2],
        [-1.0, 0.7, -0.1], [0.2, 0.8, 0.1], [1.4, 0.9, 0.0],
    ])
    angle = np.deg2rad(32.0)
    rotation = np.asarray([
        [np.cos(angle), 0.0, np.sin(angle)],
        [0.0, 1.0, 0.0],
        [-np.sin(angle), 0.0, np.cos(angle)],
    ])
    expected_scale = 2.75
    expected_translation = np.asarray([4.0, 1.2, -3.0])
    target = (expected_scale * (rotation @ source.T)).T + expected_translation
    target[-1] += np.asarray([3.0, -2.0, 4.0])  # posa volutamente corrotta

    poses = {
        str(index): {
            "image": f"{index:04d}.jpg",
            "translation": point.tolist(),
        }
        for index, point in enumerate(source)
    }
    poses_path = tmp_path / "oc_poses.json"
    poses_path.write_text(json.dumps(poses))
    transforms = {
        index: _arkit_transform(point) for index, point in enumerate(target)
    }

    calibration = oc_worker.estimate_metric_calibration(poses_path, transforms)

    assert calibration["method"] == "umeyama-oc-to-arkit-v1"
    assert calibration["scale_m_per_mesh_unit"] == pytest.approx(expected_scale)
    assert np.asarray(calibration["rotation_oc_to_arkit"]) == pytest.approx(rotation)
    assert calibration["translation_arkit_m"] == pytest.approx(expected_translation)
    assert calibration["inlier_count"] == 5
    assert calibration["pair_count"] == 6
    assert calibration["rmse_m"] < 1e-10


def test_metric_calibration_rejects_too_short_capture(tmp_path):
    poses_path = tmp_path / "oc_poses.json"
    poses_path.write_text(json.dumps({
        str(index): {"image": f"{index:04d}.jpg", "translation": [index, index % 2, 0.0]}
        for index in range(3)
    }))
    transforms = {
        index: _arkit_transform([index * 0.05, (index % 2) * 0.05, 0.0])
        for index in range(3)
    }

    with pytest.raises(RuntimeError, match="troppo corto"):
        oc_worker.estimate_metric_calibration(poses_path, transforms)


def test_bundle_manifest_publishes_metric_calibration(tmp_path):
    model = tmp_path / "model.obj"
    poses = tmp_path / "oc_poses.json"
    model.write_text("v 0 0 0\n")
    poses.write_text("{}")
    calibration = {
        "method": "umeyama-oc-to-arkit-v1",
        "scale_m_per_mesh_unit": 2.75,
        "up_vector_mesh": [0.0, 1.0, 0.0],
    }

    document = oc_worker.write_bundle_manifest(
        tmp_path / "manifest.json",
        [(model.name, str(model)), (poses.name, str(poses))],
        photo_count=3,
        detail="raw",
        metric_calibration=calibration,
    )

    assert document["metric_calibration"] == calibration
    assert document["scale_m_per_mesh_unit"] == 2.75


def test_bundle_manifest_declares_medium_projection_reference(tmp_path):
    files = []
    for name in (
        "model.obj", "oc_poses.json", "projection_proxy.obj",
        "projection_proxy.mtl", "projection_proxy_texture_1.png",
    ):
        path = tmp_path / name
        path.write_bytes(name.encode())
        files.append((name, str(path)))

    document = oc_worker.write_bundle_manifest(
        tmp_path / "manifest.json", files, photo_count=1, detail="raw",
    )

    assert document["projection_reference"] == {
        "detail": "medium",
        "model_file": "projection_proxy.obj",
        "mtl_file": "projection_proxy.mtl",
        "files": [
            "projection_proxy.obj", "projection_proxy.mtl",
            "projection_proxy_texture_1.png",
        ],
    }


def test_materialize_usdz_textures_rewrites_archive_references(tmp_path):
    usdz = tmp_path / "model.usdz"
    with zipfile.ZipFile(usdz, "w") as archive:
        archive.writestr("0/albedo.png", b"png-data")
        archive.writestr("mesh.usdc", b"usd-data")
    mtl = tmp_path / "model.mtl"
    mtl.write_text("newmtl Texture\nmap_Kd model.usdz[0/albedo.png]\n")

    textures = oc_worker.materialize_usdz_textures(usdz, mtl, tmp_path)

    assert textures == [tmp_path / "albedo.png"]
    assert textures[0].read_bytes() == b"png-data"
    assert mtl.read_text().endswith("map_Kd albedo.png\n")


def test_cached_download_reuses_a_complete_file(monkeypatch, tmp_path):
    destination = tmp_path / "asset.obj"
    destination.write_bytes(b"already cached")

    monkeypatch.setattr(
        oc_worker, "download_url",
        lambda *_args: (_ for _ in ()).throw(AssertionError("download inatteso")),
    )

    oc_worker._cached_download(
        {"name": "asset.obj", "url": "signed://asset", "size_bytes": 14},
        destination,
    )

    assert destination.read_bytes() == b"already cached"
