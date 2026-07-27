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
    "requests": ["model_file", "projection_reference", "poses"],
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
    proxy_obj = next((name for name, _ in files if name == "projection_proxy.obj"), None)
    proxy_mtl = next((name for name, _ in files if name == "projection_proxy.mtl"), None)
    if proxy_obj and proxy_mtl:
        proxy_files = [
            name for name, _ in files
            if name in {proxy_obj, proxy_mtl}
            or name.startswith("projection_proxy_texture_")
        ]
        document["projection_reference"] = {
            "detail": "medium",
            "model_file": proxy_obj,
            "mtl_file": proxy_mtl,
            "files": proxy_files,
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


def flatten_projection_proxy(source_dir: Path, output_dir: Path) -> list[Path]:
    """Copy a converted proxy into the flat OC bundle with collision-free names."""
    source_obj = source_dir / "projection_proxy.obj"
    source_mtl = source_dir / "projection_proxy.mtl"
    if not source_obj.exists() or not source_mtl.exists():
        raise RuntimeError("Conversione projection proxy incompleta")

    images = [
        path for path in source_dir.iterdir()
        if path.suffix.lower() in {".png", ".jpg", ".jpeg"}
    ]
    renamed: dict[str, str] = {}
    copied: list[Path] = []
    for index, image in enumerate(sorted(images), 1):
        suffix = image.suffix.lower()
        name = f"projection_proxy_texture_{index}{suffix}"
        destination = output_dir / name
        shutil.copy2(image, destination)
        renamed[image.name] = name
        copied.append(destination)

    output_mtl = output_dir / "projection_proxy.mtl"
    lines = []
    for line in source_mtl.read_text(errors="ignore").splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2 and parts[0].lower().startswith("map_"):
            original = Path(parts[1]).name
            line = f"{parts[0]} {renamed.get(original, original)}"
        lines.append(line)
    output_mtl.write_text("\n".join(lines) + "\n")

    output_obj = output_dir / "projection_proxy.obj"
    obj_lines = []
    for line in source_obj.read_text(errors="ignore").splitlines():
        if line.lower().startswith("mtllib "):
            line = "mtllib projection_proxy.mtl"
        obj_lines.append(line)
    output_obj.write_text("\n".join(obj_lines) + "\n")
    return [output_obj, output_mtl, *copied]


class Client:
    def __init__(self, base: str, dry: bool = False):
        self.base = base.rstrip("/")
        self.dry = dry
        token = os.environ.get("WORKER_TOKEN", "").strip()
        self.headers = {"X-Worker-Token": token} if token else {}

    def next_job(self) -> dict:
        r = requests.get(
            f"{self.base}/facade-sessions/next-oc-job",
            headers=self.headers, timeout=30)
        r.raise_for_status()
        return r.json()

    def next_projection_job(self) -> dict:
        r = requests.get(
            f"{self.base}/facade-sessions/next-projection-job",
            headers=self.headers, timeout=30)
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
            headers=self.headers,
            timeout=30,
        ).raise_for_status()

    @staticmethod
    def _upload_descriptors(paths: list[tuple[str, str | Path]]) -> list[dict]:
        return [{
            "name": name,
            "size_bytes": Path(path).stat().st_size,
            "checksum": sha256_file(path),
        } for name, path in paths]

    @staticmethod
    def _put_direct_files(
        targets: list[dict], paths: list[tuple[str, str | Path]],
    ) -> list[dict]:
        local = {name: Path(path) for name, path in paths}
        descriptors = {
            item["name"]: item for item in Client._upload_descriptors(paths)
        }
        records = []
        for target in targets:
            name = target["name"]
            path = local.get(name)
            if path is None:
                raise RuntimeError(f"Ticket upload senza file locale: {name}")
            with path.open("rb") as handle:
                response = requests.put(
                    target["url"],
                    data=handle,
                    headers=target.get("headers") or {},
                    timeout=1800,
                )
            response.raise_for_status()
            records.append({
                **descriptors[name],
                "path": target["path"],
            })
        return records

    def upload_projection(
        self, sid: str, job_id: str, manifest: dict, output_dir: Path,
    ):
        paths = [path for path in sorted(output_dir.iterdir()) if path.is_file()]
        if self.dry:
            print(f"  [dry] upload projection: {[p.name for p in paths]}")
            return
        named_paths = [(path.name, path) for path in paths]
        ticket = requests.post(
            f"{self.base}/facade-sessions/{sid}/projection-worker-upload-tickets",
            json={
                "job_id": job_id,
                "files": self._upload_descriptors(named_paths),
            },
            headers=self.headers,
            timeout=30,
        )
        if ticket.status_code not in {404, 405, 503}:
            ticket.raise_for_status()
            records = self._put_direct_files(ticket.json()["files"], named_paths)
            response = requests.post(
                f"{self.base}/facade-sessions/{sid}/projection-worker-complete",
                json={"job_id": job_id, "manifest": manifest, "files": records},
                headers=self.headers,
                timeout=120,
            )
            response.raise_for_status()
            return

        print("  backend senza upload diretto R2: uso multipart legacy")
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
                headers=self.headers,
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
                json={"job_id": job_id, "reason": reason[:500]},
                headers=self.headers, timeout=30,
            )
        except Exception:
            pass

    def upload_mesh(self, sid: str, files: list[tuple[str, str]], kind: str = "raw"):
        if self.dry:
            print(f"  [dry] PUT /{sid}/mesh?kind={kind} {[n for n, _ in files]}"); return
        descriptors = self._upload_descriptors(files)
        ticket = requests.post(
            f"{self.base}/facade-sessions/{sid}/mesh/upload-tickets",
            json={"kind": kind, "files": descriptors},
            headers=self.headers,
            timeout=30,
        )
        if ticket.status_code not in {404, 405, 503}:
            ticket.raise_for_status()
            records = self._put_direct_files(ticket.json()["files"], files)
            response = requests.post(
                f"{self.base}/facade-sessions/{sid}/mesh/complete",
                json={"kind": kind, "files": records},
                headers=self.headers,
                timeout=120,
            )
            response.raise_for_status()
            return

        print("  backend senza upload diretto R2: uso multipart legacy")
        handles = [open(path, "rb") for _, path in files]
        try:
            multipart = [
                ("files", (name, handle))
                for (name, _), handle in zip(files, handles)
            ]
            r = requests.put(f"{self.base}/facade-sessions/{sid}/mesh",
                             data={"kind": kind}, files=multipart,
                             headers=self.headers, timeout=600)
            r.raise_for_status()
        finally:
            for handle in handles:
                handle.close()

    def mesh_ready(self, sid: str):
        if self.dry:
            print(f"  [dry] POST /{sid}/mesh-ready"); return
        requests.post(
            f"{self.base}/facade-sessions/{sid}/mesh-ready",
            headers=self.headers, timeout=30).raise_for_status()

    def fail(self, sid: str, reason: str):
        if self.dry:
            print(f"  [dry] POST /{sid}/fail: {reason}"); return
        try:
            requests.post(f"{self.base}/facade-sessions/{sid}/fail",
                          json={"reason": reason[:500]},
                          headers=self.headers, timeout=30)
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
        projection_usdz = Path(tmp) / "model_projection.usdz"
        poses = Path(tmp) / "oc_poses.json"
        obj = Path(tmp) / "model.obj"
        if dry:
            print(f"  [dry] {hpg} {pdir} {usdz} {detail} sequential high")
            print(f"  [dry] {converter} {usdz} {obj}")
            print(f"  [dry] {converter} {projection_usdz} projection_proxy.obj")
        else:
            subprocess.run([hpg, str(pdir), str(usdz), detail, "sequential", "high"], check=True)
            n = merge_intrinsics(str(poses), intr)
            print(f"  intrinseci uniti a {n}/{len(photos)} pose")
            subprocess.run([converter, str(usdz), str(obj)], check=True)
            textures = materialize_usdz_textures(
                usdz, obj.with_suffix(".mtl"), Path(tmp),
            )
            print(f"  texture USDZ estratte: {len(textures)}")
            if not projection_usdz.exists():
                raise RuntimeError("Object Capture non ha prodotto il riferimento .medium")
            proxy_dir = Path(tmp) / "projection_proxy"
            proxy_dir.mkdir()
            proxy_obj = proxy_dir / "projection_proxy.obj"
            subprocess.run(
                [converter, str(projection_usdz), str(proxy_obj)], check=True,
            )
            proxy_textures = materialize_usdz_textures(
                projection_usdz, proxy_obj.with_suffix(".mtl"), proxy_dir,
            )
            proxy_files = flatten_projection_proxy(proxy_dir, Path(tmp))
            print(
                f"  riferimento proiezione: {len(proxy_files)} file, "
                f"{len(proxy_textures)} texture"
            )
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


def projection_cache_root() -> Path:
    configured = os.environ.get("ACRO_PROJECTION_CACHE_DIR", "").strip()
    root = (
        Path(configured).expanduser()
        if configured
        else Path.home() / "Library" / "Caches" / "AcrobaticaProjectionWorker"
    )
    root.mkdir(parents=True, exist_ok=True)
    return root


def _cached_download(record: dict, destination: Path) -> None:
    expected_size = record.get("size_bytes")
    if destination.exists() and (
        not expected_size or destination.stat().st_size == int(expected_size)
    ):
        return
    temporary = destination.with_name(
        f".{destination.name}.{uuid.uuid4().hex}.part"
    )
    try:
        download_url(record["url"], temporary)
        expected_hash = str(record.get("sha256") or "")
        if expected_hash and sha256_file(temporary) != expected_hash:
            raise RuntimeError(f"Checksum non valido per {record['name']}")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def _obj_face_count(path: Path) -> int:
    with path.open("rb") as handle:
        return sum(1 for line in handle if line.startswith(b"f "))


def _limit_proxy_texture_resolution(mtl: Path, max_edge: int = 4096) -> None:
    import cv2

    names = []
    for line in mtl.read_text(errors="ignore").splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2 and parts[0].lower() == "map_kd":
            names.append(Path(parts[1]).name)
    for name in dict.fromkeys(names):
        path = mtl.parent / name
        image = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if image is None or max(image.shape[:2]) <= max_edge:
            continue
        scale = max_edge / float(max(image.shape[:2]))
        resized = cv2.resize(
            image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA,
        )
        if not cv2.imwrite(str(path), resized):
            raise RuntimeError(f"Impossibile ridurre la texture proxy {path.name}")


def _build_legacy_projection_proxy(
    reference: dict[str, Path], cache_directory: Path,
    target_faces: int = 180_000,
) -> dict[str, Path]:
    """Create a cached proxy for bundles produced before the medium OC output."""
    source_obj = reference["obj"]
    if _obj_face_count(source_obj) <= target_faces * 1.25:
        return reference
    blender = os.environ.get("ACRO_BLENDER", "").strip() or shutil.which("blender")
    if not blender:
        blender = next((
            str(path) for path in (
                Path("/opt/homebrew/bin/blender"),
                Path("/usr/local/bin/blender"),
                Path("/Applications/Blender.app/Contents/MacOS/Blender"),
            ) if path.exists()
        ), "")
    if not blender:
        print("  Blender assente: uso il riferimento OC raw")
        return reference

    proxy_dir = cache_directory / "generated_proxy"
    proxy_obj = proxy_dir / "projection_proxy.obj"
    proxy_mtl = proxy_dir / "projection_proxy.mtl"
    if proxy_obj.exists() and proxy_mtl.exists():
        return {"obj": proxy_obj, "mtl": proxy_mtl}

    proxy_dir.mkdir(parents=True, exist_ok=True)
    script = Path(__file__).with_name("build_projection_proxy_blender.py")
    temporary_obj = proxy_dir / "projection_proxy.building.obj"
    subprocess.run([
        blender, "-b", "--python", str(script), "--",
        str(source_obj), str(temporary_obj), str(target_faces),
    ], check=True)
    temporary_mtl = temporary_obj.with_suffix(".mtl")
    if not temporary_obj.exists() or not temporary_mtl.exists():
        raise RuntimeError("Blender non ha prodotto il projection proxy")
    temporary_obj.replace(proxy_obj)
    temporary_mtl.replace(proxy_mtl)
    obj_lines = []
    for line in proxy_obj.read_text(errors="ignore").splitlines():
        if line.lower().startswith("mtllib "):
            line = "mtllib projection_proxy.mtl"
        obj_lines.append(line)
    proxy_obj.write_text("\n".join(obj_lines) + "\n")
    normalized = []
    for line in proxy_mtl.read_text(errors="ignore").splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2 and parts[0].lower().startswith("map_"):
            line = f"{parts[0]} {Path(parts[1]).name}"
        normalized.append(line)
    proxy_mtl.write_text("\n".join(normalized) + "\n")
    _limit_proxy_texture_resolution(proxy_mtl)
    print(
        f"  proxy legacy pronto: {_obj_face_count(source_obj)} -> "
        f"{_obj_face_count(proxy_obj)} triangoli"
    )
    return {"obj": proxy_obj, "mtl": proxy_mtl}


def prepare_raw_reference(
    records: list[dict], root: Path, *, cache_key: str = "",
    build_legacy_proxy: bool = False,
) -> dict | None:
    if not records:
        return None
    safe_key = "".join(
        character for character in cache_key
        if character.isalnum() or character in {"-", "_"}
    )
    directory = (
        projection_cache_root() / "references" / safe_key
        if safe_key else root / "raw_reference"
    )
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    for record in records:
        destination = directory / Path(record["name"]).name
        _cached_download(record, destination)
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
    reference = {"obj": obj, "mtl": mtl}
    if build_legacy_proxy:
        return _build_legacy_projection_proxy(reference, directory)
    return reference


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

        raw_reference = prepare_raw_reference(
            job.get("raw_reference", []), root,
            cache_key=str(job.get("reference_cache_key") or ""),
            build_legacy_proxy=job.get("reference_kind") != "projection_proxy",
        )
        photos_dir = root / "photos"
        photos_dir.mkdir()
        photo_cache = projection_cache_root() / "photos" / sid
        photo_cache.mkdir(parents=True, exist_ok=True)
        downloaded = [0]
        reported_progress = [0.06]

        def report(progress: float, message: str) -> None:
            reported_progress[0] = max(reported_progress[0], progress)
            cli.projection_progress(
                sid, job_id, reported_progress[0], message,
            )

        def resolve_photo(key: str) -> str | None:
            record = photo_records.get(str(int(key)))
            if not record:
                return None
            local = photo_cache / f"{int(key):04d}.jpg"
            if not local.exists():
                _cached_download(record, local)
                downloaded[0] += 1
                report(0.12, f"Mac: scarico foto selezionate {downloaded[0]}")
            return str(local)

        cfg = job.get("config") or {}
        scale = float(planes.get(
            "scale_m_per_mesh_unit", cfg.get("default_scale", 6.0927)))
        out_dir = root / "output"
        fallback_reason = ""

        def plane_progress(done: int, total: int, name: str, verb: str) -> None:
            report(
                0.15 + 0.75 * done / max(total, 1),
                f"Mac: {verb} piano {done}/{total}: {name}")

        enhanced = bool(raw_reference) and bool(cfg.get("oc_reference_bake", True))
        if enhanced:
            try:
                report(0.14, "Mac: allineo le foto al riferimento Object Capture")
                summary = oc_reference_bake.bake_planes(
                    str(mesh), str(raw_reference["obj"]), str(raw_reference["mtl"]),
                    poses, str(photos_dir), planes, str(out_dir),
                    texel_mm=float(cfg.get("texel_mm", 20.0)),
                    max_photos=int(cfg.get("max_photos", 12)),
                    target_long_edge_px=int(cfg.get("target_long_edge_px", 0)),
                    target_height_px=int(cfg.get("target_height_px", 3000)),
                    registration_ceiling=int(cfg.get("registration_ceiling", 12)),
                    coverage_photos=int(cfg.get("coverage_photos", 24)),
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
                    target_long_edge_px=int(cfg.get("target_long_edge_px", 0)),
                    target_height_px=int(cfg.get("target_height_px", 3000)),
                    max_photos=int(cfg.get("max_photos", 12)),
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
                target_long_edge_px=int(cfg.get("target_long_edge_px", 0)),
                target_height_px=int(cfg.get("target_height_px", 3000)),
                max_photos=int(cfg.get("max_photos", 12)),
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
        report(0.94, "Mac: carico il bundle finale")
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
