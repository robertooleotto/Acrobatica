import importlib.util
import json
from pathlib import Path


MODULE_PATH = (
    Path(__file__).parents[1]
    / "photogrammetry" / "objectcapture" / "oc_worker.py"
)
SPEC = importlib.util.spec_from_file_location("oc_worker", MODULE_PATH)
oc_worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(oc_worker)


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
