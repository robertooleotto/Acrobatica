#!/usr/bin/env python3
# oc_worker.py — Worker Object Capture (opzione A: gira sul Mac dedicato sempre acceso).
#
# Loop: reclama un job dalla coda del backend (sessioni in `queued_oc`), scarica le
# foto, esegue Object Capture (hpg), unisce gli intrinseci ARKit alle pose OC,
# ricarica mesh+pose sul backend e avanza lo stato a `mesh_ready`. Su errore → `fail`.
#
# Uso:
#   BACKEND=https://api.esempio.it \
#   python oc_worker.py --hpg ./hpg --detail raw [--once] [--poll 15]
#
#   --once      elabora un solo job e termina (per test/cron)
#   --poll N    secondi tra un polling e l'altro quando la coda è vuota (default 15)
#   --dry-run   non esegue OC né chiamate di scrittura: stampa cosa farebbe
#
# Dipendenze: requests  (pip install requests). hpg = binario compilato da
# HelloPhotogrammetry.swift (swiftc -O HelloPhotogrammetry.swift -o hpg).
import argparse, hashlib, json, os, subprocess, sys, tempfile, time, uuid, zipfile
from datetime import datetime, timezone
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("Serve 'requests': pip install requests")


# Keep this in sync with HelloPhotogrammetry.swift and the fixed hpg invocation
# in process_job(). It is embedded in every bundle so a mesh can be reproduced
# without inferring its configuration from its filename.
DEFAULT_OC_DETAIL = "raw"

OBJECT_CAPTURE_PRESET = {
    "id": "raw-nobbox-mesh-poses-v1",
    "sample_ordering": "sequential",
    "feature_sensitivity": "high",
    "ignore_bounding_box": True,
    "object_masking_enabled": False,
    "requests": ["model_file", "poses"],
    "model_and_poses_same_session": True,
    "photo_naming": "{order_index:04d}.jpg",
}


def intrinsics_fx_fy_cx_cy(k: list) -> list | None:
    """K col-major 9 float = [fx,0,0, 0,fy,0, cx,cy,1] → [fx,fy,cx,cy]."""
    if not k or len(k) < 9:
        return None
    return [k[0], k[4], k[6], k[7]]


def order_index_of(image_name: str) -> int | None:
    """'0007.jpg' → 7. None se non parsabile."""
    stem = Path(image_name).stem
    return int(stem) if stem.isdigit() else None


def merge_intrinsics(poses_path: str, intrinsics_by_index: dict[int, list]) -> int:
    """Aggiunge `intrinsics_fx_fy_cx_cy` a ogni posa OC, prendendo K dalla foto
    corrispondente (per order_index dedotto dal nome immagine, o dalla chiave
    sample). Riscrive il file. Ritorna quante pose sono state completate."""
    poses = json.load(open(poses_path))
    done = 0
    for sample_idx, rec in poses.items():
        oi = order_index_of(rec.get("image", "")) if rec.get("image") else None
        if oi is None and sample_idx.isdigit():
            oi = int(sample_idx)
        fxfycxcy = intrinsics_fx_fy_cx_cy(intrinsics_by_index.get(oi, [])) if oi is not None else None
        if fxfycxcy:
            rec["intrinsics_fx_fy_cx_cy"] = fxfycxcy
            done += 1
    json.dump(poses, open(poses_path, "w"), indent=2, sort_keys=True)
    return done


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_bundle_manifest(
    output_path: str | Path,
    files: list[tuple[str, str]],
    *,
    photo_count: int,
    detail: str,
) -> dict:
    """Lega mesh e pose alla singola esecuzione Object Capture corrente."""
    records = {
        name: {
            "size": Path(path).stat().st_size,
            "sha256": sha256_file(path),
        }
        for name, path in files
    }
    model_file = next(
        (name for name, _ in files if Path(name).suffix.lower() == ".obj"),
        None,
    )
    if model_file is None:
        model_file = next(
            name for name, _ in files if Path(name).suffix.lower() == ".usdz"
        )
    document = {
        "schema": "acro.oc-bundle/v1",
        "bundle_id": str(uuid.uuid4()),
        "created_at": datetime.now(timezone.utc).isoformat(),
        "photo_count": int(photo_count),
        "detail": detail,
        "object_capture": {**OBJECT_CAPTURE_PRESET, "detail": detail},
        "model_file": model_file,
        "poses_file": "oc_poses.json",
        "files": records,
    }
    Path(output_path).write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return document


def materialize_usdz_textures(
    usdz_path: str | Path,
    mtl_path: str | Path,
    output_dir: str | Path,
) -> list[Path]:
    """Estrae le texture USDZ e rende i riferimenti MTL portabili sul backend."""
    output = Path(output_dir)
    extracted: list[Path] = []
    with zipfile.ZipFile(usdz_path) as archive:
        for member in archive.namelist():
            if Path(member).suffix.lower() not in {".png", ".jpg", ".jpeg"}:
                continue
            destination = output / Path(member).name
            destination.write_bytes(archive.read(member))
            extracted.append(destination)

    mtl = Path(mtl_path)
    normalized = []
    for line in mtl.read_text(encoding="utf-8", errors="ignore").splitlines():
        stripped = line.strip().lower()
        if stripped.startswith("map_") and len(line.split(maxsplit=1)) == 2:
            command, reference = line.split(maxsplit=1)
            if "[" in reference and reference.endswith("]"):
                reference = reference.rsplit("[", 1)[1][:-1]
            line = f"{command} {Path(reference).name}"
        normalized.append(line)
    mtl.write_text("\n".join(normalized) + "\n", encoding="utf-8")
    return extracted


class Client:
    def __init__(self, base: str, dry: bool = False):
        self.base = base.rstrip("/")
        self.dry = dry

    def next_job(self) -> dict:
        r = requests.get(f"{self.base}/facade-sessions/next-oc-job", timeout=30)
        r.raise_for_status()
        return r.json()

    def upload_mesh(self, sid: str, files: list[tuple[str, str]], kind: str = "raw"):
        if self.dry:
            print(f"  [dry] PUT /{sid}/mesh?kind={kind} {[n for n, _ in files]}"); return
        handles = [open(path, "rb") for _, path in files]
        try:
            multipart = [
                ("files", (name, handle))
                for (name, _), handle in zip(files, handles)
            ]
            r = requests.put(f"{self.base}/facade-sessions/{sid}/mesh",
                             data={"kind": kind}, files=multipart, timeout=600)
            r.raise_for_status()
        finally:
            for handle in handles:
                handle.close()

    def mesh_ready(self, sid: str):
        if self.dry:
            print(f"  [dry] POST /{sid}/mesh-ready"); return
        requests.post(f"{self.base}/facade-sessions/{sid}/mesh-ready", timeout=30).raise_for_status()

    def fail(self, sid: str, reason: str):
        if self.dry:
            print(f"  [dry] POST /{sid}/fail: {reason}"); return
        try:
            requests.post(f"{self.base}/facade-sessions/{sid}/fail",
                          json={"reason": reason[:500]}, timeout=30)
        except Exception:
            pass


def process_job(cli: Client, job: dict, hpg: str, converter: str,
                detail: str, dry: bool) -> None:
    sid = job["session_id"]
    photos = job.get("photos", [])
    print(f"▶ job {sid}: {len(photos)} foto, detail={detail}")
    with tempfile.TemporaryDirectory(prefix=f"oc_{sid[:8]}_") as tmp:
        pdir = Path(tmp) / "photos"; pdir.mkdir()
        intr: dict[int, list] = {}
        for ph in photos:
            oi = ph["order_index"]
            intr[oi] = ph.get("camera_intrinsics") or []
            dest = pdir / f"{oi:04d}.jpg"
            if dry:
                print(f"  [dry] download → {dest.name}"); dest.write_bytes(b"")
            else:
                data = requests.get(ph["url"], timeout=120).content
                dest.write_bytes(data)
        usdz = Path(tmp) / "model.usdz"
        poses = Path(tmp) / "oc_poses.json"
        obj = Path(tmp) / "model.obj"
        if dry:
            print(f"  [dry] {hpg} {pdir} {usdz} {detail} sequential high")
            print(f"  [dry] {converter} {usdz} {obj}")
        else:
            subprocess.run([hpg, str(pdir), str(usdz), detail, "sequential", "high"], check=True)
            n = merge_intrinsics(str(poses), intr)
            print(f"  intrinseci uniti a {n}/{len(photos)} pose")
            subprocess.run([converter, str(usdz), str(obj)], check=True)
            textures = materialize_usdz_textures(
                usdz, obj.with_suffix(".mtl"), Path(tmp),
            )
            print(f"  texture USDZ estratte: {len(textures)}")
        generated = [("model.usdz", str(usdz)), ("oc_poses.json", str(poses))]
        mesh_suffixes = {".obj", ".mtl", ".png", ".jpg", ".jpeg"}
        generated += [
            (path.name, str(path)) for path in sorted(Path(tmp).iterdir())
            if path.is_file() and path.suffix.lower() in mesh_suffixes
        ]
        if not dry:
            bundle_manifest = Path(tmp) / "oc_bundle_manifest.json"
            bundle = write_bundle_manifest(
                bundle_manifest,
                generated,
                photo_count=len(photos),
                detail=detail,
            )
            generated.append((bundle_manifest.name, str(bundle_manifest)))
            print(f"  bundle OC {bundle['bundle_id']} verificato")
        cli.upload_mesh(sid, generated)
        cli.mesh_ready(sid)
    print(f"✔ job {sid} → mesh_ready")


def main():
    ap = argparse.ArgumentParser(description="Worker Object Capture (opzione A)")
    ap.add_argument("--backend", default=os.environ.get("BACKEND", "http://localhost:8000"))
    ap.add_argument("--hpg", default="./hpg", help="binario Object Capture")
    ap.add_argument("--converter", default="./usdz2obj",
                    help="binario USDZ -> OBJ/MTL/texture")
    ap.add_argument(
        "--detail",
        default=DEFAULT_OC_DETAIL,
        choices=("preview", "reduced", "medium", "full", "raw"),
        help="dettaglio Object Capture (default: raw)",
    )
    ap.add_argument("--poll", type=int, default=15, help="secondi tra i polling a coda vuota")
    ap.add_argument("--once", action="store_true", help="elabora un job e termina")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    cli = Client(args.backend, dry=args.dry_run)
    print(f"worker OC → backend {args.backend}  detail={args.detail}  hpg={args.hpg}")
    while True:
        try:
            job = cli.next_job()
        except Exception as e:
            print(f"[warn] next-oc-job fallito: {e}"); time.sleep(args.poll); continue
        if not job.get("session_id"):
            if args.once:
                print("coda vuota, esco (--once)"); return
            time.sleep(args.poll); continue
        sid = job["session_id"]
        try:
            process_job(cli, job, args.hpg, args.converter, args.detail, args.dry_run)
        except Exception as e:
            print(f"✗ job {sid} FALLITO: {e}")
            cli.fail(sid, str(e))
        if args.once:
            return


if __name__ == "__main__":
    main()
