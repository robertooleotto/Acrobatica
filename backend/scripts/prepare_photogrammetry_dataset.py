"""Prepare a local photogrammetry dataset bundle for external processors.

Usage:
    ./venv/bin/python scripts/prepare_photogrammetry_dataset.py 1553ab3c
    ./venv/bin/python scripts/prepare_photogrammetry_dataset.py data/fixtures/1553ab3c
"""
from __future__ import annotations

import json
import shutil
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "data" / "fixtures"
RUNS = ROOT / "data" / "photogrammetry-runs"


def resolve_fixture(arg: str) -> Path:
    path = Path(arg)
    if not path.is_absolute():
        direct = ROOT / path
        if direct.exists():
            path = direct
        else:
            path = FIXTURES / arg
    if not path.exists() or not (path / "photos").is_dir():
        raise SystemExit(f"Fixture non trovata o senza photos/: {path}")
    return path.resolve()


def zip_dir(src_dir: Path, out_zip: Path) -> None:
    out_zip.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(src_dir.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(src_dir.parent))


def main(arg: str) -> None:
    fixture = resolve_fixture(arg)
    dataset = fixture.name
    photos_dir = fixture / "photos"
    photos = sorted(photos_dir.glob("*.jpg"))
    if not photos:
        raise SystemExit(f"Nessuna foto JPG trovata in {photos_dir}")

    run_root = RUNS / dataset
    inputs = run_root / "input"
    autodesk = run_root / "autodesk"
    realityscan = run_root / "realityscan"
    for d in (inputs, autodesk, realityscan):
        d.mkdir(parents=True, exist_ok=True)

    bundle_zip = inputs / f"{dataset}_photos.zip"
    zip_dir(photos_dir, bundle_zip)

    manifest = {
        "dataset": dataset,
        "source_fixture": str(fixture),
        "prepared_at": datetime.now(timezone.utc).isoformat(),
        "photo_count": len(photos),
        "photo_dir": str(photos_dir),
        "input_zip": str(bundle_zip),
        "autodesk_output_dir": str(autodesk),
        "realityscan_output_dir": str(realityscan),
        "first_photo": photos[0].name,
        "last_photo": photos[-1].name,
    }
    for name in ("session.json", "photos.json"):
        src = fixture / name
        if src.exists():
            shutil.copy2(src, inputs / name)
            manifest[name] = str(inputs / name)

    (run_root / "manifest.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8"
    )

    print(f"Dataset: {dataset}")
    print(f"Foto:    {len(photos)}")
    print(f"Run dir: {run_root}")
    print(f"ZIP:     {bundle_zip} ({bundle_zip.stat().st_size / 1024 / 1024:.1f} MB)")
    print(f"Manifest:{run_root / 'manifest.json'}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])

