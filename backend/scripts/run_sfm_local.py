"""SfM full-auto via COLMAP/pycolmap → fit piano muro → ortorettifica
→ composite. Niente input utente: la pipeline ricostruisce camera poses
raffinate (bundle adjustment) e nuvola di punti 3D dalle sole foto.

Pipeline:
  1. Scarica foto della sessione (da Supabase o fixture locale).
  2. Salva le immagini in `/tmp/sfm_<sid>/images/`.
  3. COLMAP feature extraction (SIFT).
  4. COLMAP exhaustive feature matching N×N.
  5. COLMAP mapper (incremental SfM) → sparse reconstruction.
  6. Esporta camera poses raffinate + sparse point cloud.
  7. Fit del piano muro (RANSAC + SVD) sui punti 3D.
  8. Ortorettifica ogni foto sul piano (riusa orthorectify_service).
  9. Composite + apertura in Preview.

Uso:
    python scripts/run_sfm_local.py <session_id_prefix>
    python scripts/run_sfm_local.py data/fixtures/<id>

Output in /tmp/sfm_<sid>/:
    images/                 (foto JPEG)
    database.db             (COLMAP feature DB)
    sparse/0/               (sparse reconstruction binaria)
    sparse_text/            (camera poses + punti 3D in TXT)
    wall_plane.json         (piano fittato)
    ortho/                  (foto ortografate)
    facade_sfm_composite.jpg  (composite finale)
"""
from __future__ import annotations
import argparse
import sys, json, subprocess, shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

import cv2
import numpy as np
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")

from _session_source import SessionSource


def have_pycolmap() -> bool:
    try:
        import pycolmap  # noqa
        return True
    except ImportError:
        return False


def have_colmap_cli() -> bool:
    return shutil.which("colmap") is not None


def run_pycolmap(
    work_dir: Path,
    images_dir: Path,
    sparse_dir: Path,
    *,
    matcher: str = "exhaustive",
    sequential_overlap: int = 10,
    mask_path: Path | None = None,
):
    """Esegue feature extraction + matching + mapper via pycolmap."""
    import pycolmap
    print("[1/3] Feature extraction (SIFT)…", flush=True)
    db_path = work_dir / "database.db"
    if db_path.exists(): db_path.unlink()
    sift_e = pycolmap.SiftExtractionOptions()
    sift_e.use_gpu = False
    reader_options = pycolmap.ImageReaderOptions()
    if mask_path is not None:
        reader_options.mask_path = str(mask_path)
    pycolmap.extract_features(
        database_path=str(db_path),
        image_path=str(images_dir),
        reader_options=reader_options,
        sift_options=sift_e,
        device=pycolmap.Device.cpu,
    )
    print(f"[2/3] Feature matching ({matcher})…", flush=True)
    sift_m = pycolmap.SiftMatchingOptions()
    sift_m.use_gpu = False
    if matcher == "sequential":
        seq_m = pycolmap.SequentialMatchingOptions()
        seq_m.overlap = sequential_overlap
        seq_m.quadratic_overlap = True
        pycolmap.match_sequential(
            database_path=str(db_path),
            sift_options=sift_m,
            matching_options=seq_m,
            device=pycolmap.Device.cpu,
        )
    elif matcher == "exhaustive":
        pycolmap.match_exhaustive(
            database_path=str(db_path),
            sift_options=sift_m,
            device=pycolmap.Device.cpu,
        )
    else:
        raise ValueError(f"matcher non supportato: {matcher}")
    print("[3/3] Incremental mapping (bundle adjustment)…", flush=True)
    sparse_dir.mkdir(parents=True, exist_ok=True)
    maps = pycolmap.incremental_mapping(
        database_path=str(db_path),
        image_path=str(images_dir),
        output_path=str(sparse_dir),
    )
    return maps   # dict[int, Reconstruction]


def run_colmap_cli(work_dir: Path, images_dir: Path, sparse_dir: Path):
    """Esegue COLMAP via subprocess (fallback se pycolmap non disponibile)."""
    db = work_dir / "database.db"
    if db.exists(): db.unlink()
    sparse_dir.mkdir(parents=True, exist_ok=True)
    cmds = [
        ["colmap", "feature_extractor",
            "--database_path", str(db),
            "--image_path", str(images_dir),
            "--SiftExtraction.use_gpu", "0"],
        ["colmap", "exhaustive_matcher",
            "--database_path", str(db),
            "--SiftMatching.use_gpu", "0"],
        ["colmap", "mapper",
            "--database_path", str(db),
            "--image_path", str(images_dir),
            "--output_path", str(sparse_dir)],
    ]
    for c in cmds:
        print("[colmap]", " ".join(c[1:3]), "…")
        subprocess.run(c, check=True)


def parse_sparse_text(sparse_text_dir: Path):
    """Legge cameras.txt, images.txt, points3D.txt esportati da COLMAP.
    Ritorna (cameras: dict, images: dict, points: np.ndarray Nx3)."""
    cameras = {}
    for line in (sparse_text_dir / "cameras.txt").read_text().splitlines():
        if not line or line.startswith("#"): continue
        parts = line.split()
        cam_id = int(parts[0])
        model = parts[1]
        w, h = int(parts[2]), int(parts[3])
        params = [float(x) for x in parts[4:]]
        cameras[cam_id] = {"model": model, "width": w, "height": h, "params": params}

    images = {}
    lines = (sparse_text_dir / "images.txt").read_text().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line or line.startswith("#"): continue
        parts = line.split()
        img_id = int(parts[0])
        qw, qx, qy, qz = map(float, parts[1:5])  # quaternion
        tx, ty, tz = map(float, parts[5:8])
        cam_id = int(parts[8])
        name = parts[9]
        # Next line: 2D points (skip)
        i += 1
        images[img_id] = {
            "q": (qw, qx, qy, qz), "t": (tx, ty, tz),
            "cam_id": cam_id, "name": name,
        }

    pts = []
    for line in (sparse_text_dir / "points3D.txt").read_text().splitlines():
        if not line or line.startswith("#"): continue
        parts = line.split()
        # POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[]
        pts.append([float(parts[1]), float(parts[2]), float(parts[3])])
    return cameras, images, np.array(pts, dtype=np.float64)


COLMAP_TO_ARKIT_CAMERA = np.diag([1.0, -1.0, -1.0])


def colmap_intrinsics_col9(camera) -> list[float]:
    """Converte una camera COLMAP in formato intrinsics col-major usato dall'app.

    Distorsione ignorata per ora: COLMAP stima SIMPLE_RADIAL, mentre la nostra
    ortorettifica usa una K pinhole. Il prossimo livello corretto è undistortare
    le immagini prima della proiezione.
    """
    fx = float(camera.focal_length_x)
    fy = float(camera.focal_length_y)
    cx = float(camera.principal_point_x)
    cy = float(camera.principal_point_y)
    return [fx, 0.0, 0.0, 0.0, fy, 0.0, cx, cy, 1.0]


def colmap_pose_as_arkit_transform(image) -> list[float]:
    """Converte pose COLMAP world→camera in camera_transform ARKit-like.

    COLMAP camera frame: +X right, +Y down, +Z forward.
    ARKit-like frame atteso da orthorectify_service: +X right, +Y up, -Z forward.
    """
    cam_from_world = image.cam_from_world().matrix()
    r_world_to_colmap_cam = np.asarray(cam_from_world[:3, :3], dtype=np.float64)
    t_world_to_colmap_cam = np.asarray(cam_from_world[:3, 3], dtype=np.float64)
    camera_center = -r_world_to_colmap_cam.T @ t_world_to_colmap_cam

    r_world_to_arkit_cam = COLMAP_TO_ARKIT_CAMERA @ r_world_to_colmap_cam
    r_arkit_cam_to_world = r_world_to_arkit_cam.T

    t = np.eye(4, dtype=np.float64)
    t[:3, :3] = r_arkit_cam_to_world
    t[:3, 3] = camera_center
    return t.reshape(-1, order="F").tolist()


def preprocess_for_feature_matching(img: np.ndarray, mode: str) -> np.ndarray:
    """Prepara una copia tecnica per SfM senza alterare geometria/dimensioni."""
    if mode == "none":
        return img
    if mode != "contrast":
        raise ValueError(f"feature-preprocess non supportato: {mode}")

    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    clahe = cv2.createCLAHE(clipLimit=2.2, tileGridSize=(8, 8))
    l = clahe.apply(l)
    enhanced = cv2.cvtColor(cv2.merge([l, a, b]), cv2.COLOR_LAB2BGR)

    # Unsharp mask leggero: aumenta angoli/cornici, ma evita artefatti forti.
    blur = cv2.GaussianBlur(enhanced, (0, 0), 1.1)
    sharp = cv2.addWeighted(enhanced, 1.35, blur, -0.35, 0)
    return sharp


def build_feature_mask(img: np.ndarray, mode: str) -> np.ndarray:
    """Maschera per estrazione feature: bianco = usa, nero = ignora."""
    h, w = img.shape[:2]
    mask = np.full((h, w), 255, dtype=np.uint8)
    if mode == "none":
        return mask
    if mode != "facade_roi":
        raise ValueError(f"feature-mask non supportata: {mode}")

    # Taglio prudente: elimina zone che spesso contengono cielo/strada/auto.
    mask[: int(h * 0.035), :] = 0
    mask[int(h * 0.86) :, :] = 0
    mask[:, : int(w * 0.015)] = 0
    mask[:, int(w * 0.985) :] = 0

    # Cielo: blu/ciano molto saturo e luminoso. Lo dilatiamo perché i bordi del
    # cielo vicino ai tetti creano match instabili.
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    hue = hsv[..., 0]
    sat = hsv[..., 1]
    val = hsv[..., 2]
    sky = ((hue >= 88) & (hue <= 116) & (sat > 35) & (val > 110)).astype(np.uint8) * 255
    sky = cv2.morphologyEx(
        sky,
        cv2.MORPH_CLOSE,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (17, 17)),
        iterations=1,
    )
    sky = cv2.dilate(sky, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (25, 25)), iterations=1)
    mask[sky > 0] = 0

    return mask


def estimate_colmap_world_up(recon) -> tuple[float, float, float]:
    """Stima la direzione 'alto' nel mondo COLMAP mediando l'up delle camere."""
    ups = []
    for image in recon.images.values():
        if not image.has_pose:
            continue
        cam_to_world = np.asarray(image.cam_from_world().inverse().matrix()[:3, :3], dtype=np.float64)
        ups.append(-cam_to_world[:, 1])  # COLMAP +Y è verso il basso immagine
    if not ups:
        return (0.0, 1.0, 0.0)
    up = np.mean(np.vstack(ups), axis=0)
    n = np.linalg.norm(up)
    if n < 1e-9:
        return (0.0, 1.0, 0.0)
    return tuple((up / n).tolist())


def reconstruction_score(recon) -> tuple[int, int]:
    return (recon.num_reg_images(), recon.num_points3D())


def main(
    arg: str,
    *,
    max_dim: int = 2400,
    out_dir: str | None = None,
    matcher: str = "exhaustive",
    sequential_overlap: int = 10,
    pose_source: str = "arkit",
    feature_preprocess: str = "none",
    feature_mask: str = "none",
    max_photos: int = 0,
) -> None:
    if not have_pycolmap() and not have_colmap_cli():
        raise SystemExit(
            "COLMAP non trovato. Installa con:\n"
            "  pip install pycolmap        (in venv)\n"
            "oppure\n"
            "  brew install colmap"
        )

    src = SessionSource.open(arg)
    sid = src.sid
    if max_photos and len(src.photos) > max_photos:
        ordered = sorted(src.photos, key=lambda x: int(x["order_index"]))
        step = len(ordered) / max_photos
        src.photos = [ordered[int(i * step)] for i in range(max_photos)]
        print(f"Sottocampionamento: {max_photos} foto uniformi su {len(ordered)}")
    print(f"Sessione: {src.source_label}  ({len(src.photos)} foto)")

    work_dir = Path(out_dir) if out_dir else Path(f"/tmp/sfm_{sid[:8]}")
    images_dir = work_dir / "images"
    masks_dir = work_dir / "masks"
    sparse_dir = work_dir / "sparse"
    work_dir.mkdir(parents=True, exist_ok=True)
    images_dir.mkdir(exist_ok=True)
    if feature_mask != "none":
        masks_dir.mkdir(exist_ok=True)
    # Pulisci eventuali run precedenti
    if (work_dir / "database.db").exists():
        (work_dir / "database.db").unlink()
    if sparse_dir.exists():
        shutil.rmtree(sparse_dir)

    # 1. Scarica foto in images_dir (come PNG per compatibilità FreeImage di pycolmap)
    print(f"Scarico foto in {images_dir}…", flush=True)
    for p in sorted(src.photos, key=lambda x: int(x["order_index"])):
        order = int(p["order_index"])
        img = src.load_image(p)
        if img is None:
            print(f"  [{order}] decode fallito, skip"); continue
        # Downscale opzionale: usare --max-dim 0 per mantenere i file originali.
        h, w = img.shape[:2]
        if max_dim > 0 and max(h, w) > max_dim:
            s = max_dim / max(h, w)
            img = cv2.resize(img, (int(w*s), int(h*s)), interpolation=cv2.INTER_AREA)
        feature_img = preprocess_for_feature_matching(img, feature_preprocess)
        out = images_dir / f"{order:04d}.png"
        cv2.imwrite(str(out), feature_img)
        if feature_mask != "none":
            mask = build_feature_mask(img, feature_mask)
            cv2.imwrite(str(masks_dir / f"{order:04d}.png"), mask)
    print(f"  {len(list(images_dir.glob('*.png')))} PNG salvati", flush=True)

    print(f"\n=== COLMAP SfM ===  (può richiedere 3-10 minuti)")
    if have_pycolmap():
        maps = run_pycolmap(
            work_dir,
            images_dir,
            sparse_dir,
            matcher=matcher,
            sequential_overlap=sequential_overlap,
            mask_path=masks_dir if feature_mask != "none" else None,
        )
        print(f"  Reconstructions: {len(maps)}")
    else:
        run_colmap_cli(work_dir, images_dir, sparse_dir)

    # 2. Esporta sparse_dir/0 in formato TXT per parsing facile
    sparse_text_dir = work_dir / "sparse_text"
    sparse_text_dir.mkdir(exist_ok=True)
    selected_recon = None
    if have_pycolmap():
        import pycolmap
        # maps è dict di Reconstruction
        if not maps:
            raise SystemExit("COLMAP non ha trovato ricostruzione (poche feature?)")
        # Prendi la ricostruzione più completa. Con facciate ripetitive COLMAP può
        # generare componenti secondarie piccole, che non devono guidare il piano.
        recon = max(maps.values(), key=reconstruction_score)
        selected_recon = recon
        print(
            "  Ricostruzione scelta: "
            f"{recon.num_reg_images()} immagini, {recon.num_points3D()} punti 3D"
        )
        recon.write_text(str(sparse_text_dir))
    else:
        subprocess.run([
            "colmap", "model_converter",
            "--input_path", str(sparse_dir / "0"),
            "--output_path", str(sparse_text_dir),
            "--output_type", "TXT",
        ], check=True)

    # 3. Parsing
    cameras, images, points3d = parse_sparse_text(sparse_text_dir)
    print(f"\nCamere registrate: {len(images)}  Punti 3D: {len(points3d)}")

    if len(points3d) < 30:
        raise SystemExit("Troppi pochi punti 3D ricostruiti — facciata troppo liscia o overlap insufficiente.")

    # 4. Fit piano muro
    from app.services.orthorectify_service import fit_plane_from_points
    # Filtra outlier via percentile
    pts_arr = points3d
    # Calcola centro nuvola
    centroid = pts_arr.mean(axis=0)
    dists = np.linalg.norm(pts_arr - centroid, axis=1)
    keep = dists < np.percentile(dists, 90)
    pts_inlier = pts_arr[keep]
    face_toward = None
    world_up = (0.0, 1.0, 0.0)
    assume_vertical = True
    if pose_source == "colmap" and selected_recon is not None:
        centers = [np.asarray(img.projection_center(), dtype=np.float64)
                   for img in selected_recon.images.values() if img.has_pose]
        if centers:
            face_toward = tuple(np.mean(np.vstack(centers), axis=0).tolist())
        world_up = estimate_colmap_world_up(selected_recon)
        assume_vertical = False

    plane = fit_plane_from_points(
        [tuple(p) for p in pts_inlier],
        world_up=world_up,
        assume_vertical=assume_vertical,
        face_toward=face_toward,
        pad_m=0.5,
    )
    print(f"piano: normale={tuple(round(x,3) for x in plane.normal)}")
    print(f"        bounds u=[{plane.u_min:.2f},{plane.u_max:.2f}] "
          f"v=[{plane.v_min:.2f},{plane.v_max:.2f}] "
          f"({plane.width_m():.1f}m × {plane.height_m():.1f}m)")
    (work_dir / "wall_plane.json").write_text(json.dumps(plane.to_dict(), indent=2))

    colmap_images_by_name = {}
    if pose_source == "colmap":
        if selected_recon is None:
            raise SystemExit("pose-source colmap richiede pycolmap")
        colmap_images_by_name = {
            image.name: image
            for image in selected_recon.images.values()
            if image.has_pose
        }

    # 5. Ortorettifica via pose ARKit oppure COLMAP raffinate.
    from app.services.orthorectify_service import orthorectify_photo, composite_orthos
    ortho_dir = work_dir / "ortho"
    ortho_dir.mkdir(exist_ok=True)
    orthos = []
    for p in sorted(src.photos, key=lambda x: int(x["order_index"])):
        order = int(p["order_index"])
        img = src.load_image(p)
        if img is None: continue
        m = p["metadata"]
        intrinsics = m["camera_intrinsics"]
        camera_transform = m["camera_transform"]
        metadata_image_size = (int(m["image_width"]), int(m["image_height"]))
        if pose_source == "colmap":
            colmap_name = f"{order:04d}.png"
            colmap_image = colmap_images_by_name.get(colmap_name)
            if colmap_image is None:
                print(f"  [{order}] nessuna posa COLMAP, skip")
                continue
            intrinsics = colmap_intrinsics_col9(colmap_image.camera)
            camera_transform = colmap_pose_as_arkit_transform(colmap_image)
            metadata_image_size = (int(colmap_image.camera.width), int(colmap_image.camera.height))
        try:
            ortho, info = orthorectify_photo(
                img, intrinsics=intrinsics,
                camera_transform=camera_transform,
                plane=plane, pixels_per_meter=120,
                metadata_image_size=metadata_image_size,
            )
        except Exception as e:
            print(f"  [{order}] ortho fallito: {e}"); continue
        cv2.imwrite(str(ortho_dir / f"{order:02d}_ortho.jpg"), ortho,
                    [cv2.IMWRITE_JPEG_QUALITY, 85])
        orthos.append(ortho)
        print(f"  [{order}] ortho {info.output_size}")

    if len(orthos) >= 2:
        comp = composite_orthos(orthos)
        comp_path = work_dir / "facade_sfm_composite.jpg"
        cv2.imwrite(str(comp_path), comp, [cv2.IMWRITE_JPEG_QUALITY, 90])
        print(f"\n→ {comp_path}  ({comp.shape[1]}×{comp.shape[0]})")
        subprocess.run(["open", "-a", "Preview", str(comp_path)], check=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("session", help="session_prefix oppure cartella fixture")
    parser.add_argument(
        "--max-dim",
        type=int,
        default=2400,
        help="lato lungo massimo per SfM; 0 mantiene la risoluzione originale",
    )
    parser.add_argument("--out-dir", default=None, help="cartella output, default /tmp/sfm_<sid>")
    parser.add_argument(
        "--matcher",
        choices=("exhaustive", "sequential"),
        default="exhaustive",
        help="strategia matching COLMAP",
    )
    parser.add_argument(
        "--sequential-overlap",
        type=int,
        default=10,
        help="quante immagini vicine confrontare nel matching sequenziale",
    )
    parser.add_argument(
        "--pose-source",
        choices=("arkit", "colmap"),
        default="arkit",
        help="pose usate per ortorettifica finale",
    )
    parser.add_argument(
        "--feature-preprocess",
        choices=("none", "contrast"),
        default="none",
        help="preparazione immagini solo per feature matching COLMAP",
    )
    parser.add_argument(
        "--feature-mask",
        choices=("none", "facade_roi"),
        default="none",
        help="maschera zone da ignorare durante feature matching COLMAP",
    )
    parser.add_argument(
        "--max-photos",
        type=int,
        default=0,
        help="campiona N foto uniformemente (0 = tutte); riduce RAM/tempo",
    )
    args = parser.parse_args()
    main(
        args.session,
        max_dim=args.max_dim,
        out_dir=args.out_dir,
        matcher=args.matcher,
        sequential_overlap=args.sequential_overlap,
        pose_source=args.pose_source,
        feature_preprocess=args.feature_preprocess,
        feature_mask=args.feature_mask,
        max_photos=args.max_photos,
    )
