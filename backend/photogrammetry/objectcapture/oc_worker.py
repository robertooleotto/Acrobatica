#!/usr/bin/env python3
# oc_worker.py — Worker Object Capture (opzione A: gira sul Mac dedicato sempre acceso).
#
# Loop: consuma sia la coda Object Capture sia la coda di proiezione. Il calcolo
# pesante resta sul Mac; Railway conserva stato, input e bundle finali.
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
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile, time, uuid, zipfile
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

    def next_projection_job(self) -> dict:
        r = requests.get(
            f"{self.base}/facade-sessions/next-projection-job", timeout=30)
        r.raise_for_status()
        return r.json()

    def projection_progress(
        self, sid: str, job_id: str, progress: float, message: str,
    ):
        if self.dry:
            print(f"  [dry] projection {progress:.0%}: {message}")
            return
        requests.post(
            f"{self.base}/facade-sessions/{sid}/projection-worker-progress",
            json={"job_id": job_id, "progress": progress, "message": message},
            timeout=30,
        ).raise_for_status()

    def upload_projection(
        self, sid: str, job_id: str, manifest: dict, output_dir: Path,
    ):
        paths = [path for path in sorted(output_dir.iterdir()) if path.is_file()]
        if self.dry:
            print(f"  [dry] upload projection: {[p.name for p in paths]}")
            return
        handles = [path.open("rb") for path in paths]
        try:
            multipart = [
                ("files", (path.name, handle))
                for path, handle in zip(paths, handles)
            ]
            response = requests.put(
                f"{self.base}/facade-sessions/{sid}/projection-worker-result",
                data={"job_id": job_id, "manifest": json.dumps(manifest)},
                files=multipart,
                timeout=1800,
            )
            response.raise_for_status()
        finally:
            for handle in handles:
                handle.close()

    def fail_projection(self, sid: str, job_id: str, reason: str):
        if self.dry:
            print(f"  [dry] projection fail: {reason}")
            return
        try:
            requests.post(
                f"{self.base}/facade-sessions/{sid}/projection-worker-fail",
                json={"job_id": job_id, "reason": reason[:500]}, timeout=30,
            )
        except Exception:
            pass

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


def download_url(url: str, destination: Path) -> None:
    """Download in streaming: anche gli OBJ grandi non vengono tenuti in RAM."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with requests.get(url, stream=True, timeout=600) as response:
        response.raise_for_status()
        with destination.open("wb") as handle:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    handle.write(chunk)


def prepare_raw_reference(records: list[dict], root: Path) -> dict | None:
    if not records:
        return None
    directory = root / "raw_reference"
    directory.mkdir()
    paths = []
    for record in records:
        destination = directory / Path(record["name"]).name
        download_url(record["url"], destination)
        paths.append(destination)
    obj = next((path for path in paths if path.suffix.lower() == ".obj"), None)
    mtls = [path for path in paths if path.suffix.lower() == ".mtl"]
    if obj is None or not mtls:
        return None
    referenced = None
    for line in obj.read_text(errors="ignore").splitlines():
        if line.lower().startswith("mtllib "):
            referenced = Path(line.split(maxsplit=1)[1].strip()).name
            break
    mtl = next((path for path in mtls if path.name == referenced), mtls[0])
    normalized = []
    for line in mtl.read_text(errors="ignore").splitlines():
        if line.strip().lower().startswith("map_kd "):
            line = f"map_Kd {Path(line.split()[-1]).name}"
        normalized.append(line)
    mtl.write_text("\n".join(normalized) + "\n")
    return {"obj": obj, "mtl": mtl}


def process_projection_job(cli: Client, job: dict, dry: bool) -> None:
    """Esegue sul Mac lo stesso bake OC-reference usato dal viewer locale."""
    sid = job["session_id"]
    job_id = job["job_id"]
    print(f"▶ projection {sid}: {len(job.get('photos', []))} foto")
    if dry:
        print("  [dry] download mesh/pose/piani/riferimento e bake proiezione")
        return

    backend_root = Path(__file__).resolve().parents[2]
    if str(backend_root) not in sys.path:
        sys.path.insert(0, str(backend_root))
    from app.services import oc_reference_bake, ortho_bake
    from app.services.plane_geometry import regularize_planes_document

    with tempfile.TemporaryDirectory(prefix=f"projection_{sid[:8]}_") as tmp:
        root = Path(tmp)
        mesh = root / "mesh.obj"
        poses_path = root / "oc_poses.json"
        planes_path = root / "planes.json"
        download_url(job["mesh"]["url"], mesh)
        download_url(job["poses"]["url"], poses_path)
        download_url(job["planes"]["url"], planes_path)
        cli.projection_progress(sid, job_id, 0.06, "Mac: input principali scaricati")

        poses = json.loads(poses_path.read_bytes())
        planes = regularize_planes_document(json.loads(planes_path.read_bytes()))
        photo_records = {str(int(item["order_index"])): item
                         for item in job.get("photos", [])}
        for key, record in photo_records.items():
            pose = poses.get(key)
            if pose is not None and record.get("image_width") and record.get("image_height"):
                pose["image_width_height"] = [
                    int(record["image_width"]), int(record["image_height"])]

        raw_reference = prepare_raw_reference(job.get("raw_reference", []), root)
        photos_dir = root / "photos"
        photos_dir.mkdir()
        downloaded = [0]

        def resolve_photo(key: str) -> str | None:
            record = photo_records.get(str(int(key)))
            if not record:
                return None
            local = photos_dir / f"{int(key):04d}.jpg"
            if not local.exists():
                download_url(record["url"], local)
                downloaded[0] += 1
                cli.projection_progress(
                    sid, job_id, 0.12,
                    f"Mac: scarico foto selezionate {downloaded[0]}",
                )
            return str(local)

        cfg = job.get("config") or {}
        scale = float(planes.get(
            "scale_m_per_mesh_unit", cfg.get("default_scale", 6.0927)))
        out_dir = root / "output"
        fallback_reason = ""

        def plane_progress(done: int, total: int, name: str, verb: str) -> None:
            cli.projection_progress(
                sid, job_id, 0.15 + 0.75 * done / max(total, 1),
                f"Mac: {verb} piano {done}/{total}: {name}",
            )

        enhanced = bool(raw_reference) and bool(cfg.get("oc_reference_bake", True))
        if enhanced:
            try:
                cli.projection_progress(
                    sid, job_id, 0.14,
                    "Mac: allineo le foto al riferimento Object Capture",
                )
                summary = oc_reference_bake.bake_planes(
                    str(mesh), str(raw_reference["obj"]), str(raw_reference["mtl"]),
                    poses, str(photos_dir), planes, str(out_dir),
                    texel_mm=float(cfg.get("texel_mm", 20.0)),
                    max_photos=int(cfg.get("max_photos", 20)),
                    target_long_edge_px=int(cfg.get("target_long_edge_px", 4096)),
                    registration_ceiling=int(cfg.get("registration_ceiling", 80)),
                    coverage_photos=int(cfg.get("coverage_photos", 100)),
                    crop=0.9, scale_m_per_mesh_unit=scale,
                    photo_resolver=resolve_photo,
                    progress=lambda done, total, name: plane_progress(
                        done, total, name, "registro"),
                )
            except Exception as exc:
                fallback_reason = str(exc)[:300]
                shutil.rmtree(out_dir, ignore_errors=True)
                summary = ortho_bake.bake_planes(
                    str(mesh), poses, str(photos_dir), planes, str(out_dir),
                    texel_mm=float(cfg.get("texel_mm", 20.0)),
                    target_long_edge_px=int(cfg.get("target_long_edge_px", 4096)),
                    max_photos=int(cfg.get("max_photos", 20)),
                    occlusion=False, facing_min=0.342, crop=0.9,
                    scale_m_per_mesh_unit=scale,
                    photo_resolver=resolve_photo,
                    available_photo_keys=set(photo_records),
                    progress=lambda done, total, name: plane_progress(
                        done, total, name, "proietto"),
                )
                summary["projection_mode"] = "pose_only_fallback"
        else:
            fallback_reason = "mesh OC testurizzata non disponibile"
            summary = ortho_bake.bake_planes(
                str(mesh), poses, str(photos_dir), planes, str(out_dir),
                texel_mm=float(cfg.get("texel_mm", 20.0)),
                target_long_edge_px=int(cfg.get("target_long_edge_px", 4096)),
                max_photos=int(cfg.get("max_photos", 20)),
                occlusion=False, facing_min=0.342, crop=0.9,
                scale_m_per_mesh_unit=scale,
                photo_resolver=resolve_photo,
                available_photo_keys=set(photo_records),
                progress=lambda done, total, name: plane_progress(
                    done, total, name, "proietto"),
            )
            summary["projection_mode"] = "pose_only_fallback"
        if summary.get("count", 0) == 0:
            raise RuntimeError("Nessun piano ha prodotto una texture")

        manifest = {
            "main_obj": summary["main_obj"],
            "planes": summary["planes"],
            "total_area_m2": summary["total_area_m2"],
            "coverage": summary["coverage"],
            "photo_count": len(photo_records),
            "scale_m_per_mesh_unit": scale,
            "projection_mode": summary.get("projection_mode", "pose_only"),
            "texture_encoding": summary.get("texture_encoding", "sRGB"),
            "fallback_reason": fallback_reason,
        }
        cli.projection_progress(sid, job_id, 0.94, "Mac: carico il bundle finale")
        cli.upload_projection(sid, job_id, manifest, out_dir)
    print(f"✔ projection {sid} → texture pronta")


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
    ap.add_argument(
        "--projection-only", action="store_true",
        help="non reclama Object Capture; esegue soltanto bake/proiezioni",
    )
    args = ap.parse_args()

    cli = Client(args.backend, dry=args.dry_run)
    print(f"worker Mac → backend {args.backend}  detail={args.detail}  hpg={args.hpg}")
    while True:
        job = {}
        kind = ""
        if not args.projection_only:
            try:
                job = cli.next_job()
                if job.get("session_id"):
                    kind = "oc"
            except Exception as e:
                print(f"[warn] next-oc-job fallito: {e}")
        if not kind:
            try:
                job = cli.next_projection_job()
                if job.get("session_id"):
                    kind = "projection"
            except Exception as e:
                print(f"[warn] next-projection-job fallito: {e}")
        if not kind:
            if args.once:
                print("coda vuota, esco (--once)"); return
            time.sleep(args.poll); continue
        sid = job["session_id"]
        try:
            if kind == "oc":
                process_job(cli, job, args.hpg, args.converter, args.detail, args.dry_run)
            else:
                process_projection_job(cli, job, args.dry_run)
        except Exception as e:
            print(f"✗ {kind} {sid} FALLITO: {e}")
            if kind == "oc":
                cli.fail(sid, str(e))
            else:
                cli.fail_projection(sid, job.get("job_id", ""), str(e))
        if args.once:
            return


if __name__ == "__main__":
    main()
