"""Pose-prior: converte le pose ARKit nella convenzione AliceVision (Meshroom 2023.3,
sfmData v1.2.3) per saltare l'SfM incrementale (computeStructureFromKnownPoses).

Math (verificata contro triangulation_service.project, già validato sui dati reali):
  ARKit camera_transform T (col-major) = camera->world.
  C  = (T12,T13,T14)                      (centro camera in world)
  R_c2w = colonne = assi camera in world  (3x3 upper-left, col-major)
  ARKit cam: +X destra, +Y su, +Z verso viewer (guarda -Z)
  AliceVision/CV: +X destra, +Y giù, +Z avanti (guarda +Z)
  => R_w2c_AV = diag(1,-1,-1) @ R_c2w^T          (world->camera, CV)
  Proiezione AV: x = K @ R_w2c @ (X - C); u=fx*Xc/Zc+cx; v=fy*Yc/Zc+cy; Zc>0.

JSON AliceVision:
  pose.transform.rotation = R_w2c flat COLUMN-MAJOR (9 stringhe)
  pose.transform.center   = [C0,C1,C2] (stringhe)
  pose.locked = "1"  -> il bundle adjustment non la muove (verificato in sorgente AV)

Uso:
  python scripts/arkit_to_alicevision.py f604436f --selftest
  python scripts/arkit_to_alicevision.py f604436f --inject /path/cameraInit.sfm --out /path/withPoses.sfm
"""
from __future__ import annotations
import sys, json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))

import numpy as np
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")
from _session_source import SessionSource

FLIP = np.diag([1.0, -1.0, -1.0])


def arkit_pose_to_av(transform16):
    """transform16: 16 float col-major (camera->world). Ritorna (R_w2c 3x3, C 3)."""
    T = np.asarray(transform16, np.float64).reshape(4, 4, order="F")  # col-major
    R_c2w = T[:3, :3]
    C = T[:3, 3].copy()
    R_w2c = FLIP @ R_c2w.T
    return R_w2c, C


def intrinsics_fxfycxcy(intr9):
    K = intr9
    return K[0], K[4], K[6], K[7]   # col-major 3x3: fx,fy,cx,cy


def av_project(R_w2c, C, fx, fy, cx, cy, X):
    """Proiezione in convenzione AliceVision. Ritorna (u,v) o None se dietro."""
    Xc = R_w2c @ (np.asarray(X, np.float64) - C)
    if Xc[2] <= 1e-9:
        return None
    return (fx * Xc[0] / Xc[2] + cx, fy * Xc[1] / Xc[2] + cy)


def selftest(arg):
    """Round-trip: pixel -> raggio ARKit -> punto 3D a distanza d -> riproiezione AV.
    Deve tornare sul pixel di partenza per ogni camera. Valida conversione + convenzione."""
    src = SessionSource.open(arg)
    photos = sorted(src.photos, key=lambda p: int(p["order_index"]))
    rng = np.random.default_rng(0)
    max_err = 0.0
    n_cams = 0
    for p in photos:
        m = p["metadata"]
        T = np.asarray(m["camera_transform"], np.float64).reshape(4, 4, order="F")
        R_c2w = T[:3, :3]; o = T[:3, 3]
        fx, fy, cx, cy = intrinsics_fxfycxcy(m["camera_intrinsics"])
        R_w2c, C = arkit_pose_to_av(m["camera_transform"])
        W = int(m["image_width"]); H = int(m["image_height"])
        for _ in range(40):
            px = float(rng.uniform(0, W)); py = float(rng.uniform(0, H))
            # raggio ARKit (come ray_from_pixel): cam looks -Z, y su
            dcam = np.array([(px - cx) / fx, -(py - cy) / fy, -1.0])
            dcam /= np.linalg.norm(dcam)
            dworld = R_c2w @ dcam
            d = rng.uniform(2.0, 30.0)
            X = o + d * dworld
            uv = av_project(R_w2c, C, fx, fy, cx, cy, X)
            if uv is None:
                raise SystemExit("ERRORE: punto davanti alla camera proiettato come dietro!")
            err = np.hypot(uv[0] - px, uv[1] - py)
            max_err = max(max_err, err)
        n_cams += 1
    print(f"self-test su {n_cams} camere: errore max round-trip = {max_err:.2e} px")
    # tolleranza 0.01px: il residuo ~1e-3 viene dai metadati salvati in float32
    print("OK ✓ conversione corretta" if max_err < 1e-2 else "FALLITO ✗")


SENSOR_W = 36.0   # mm, arbitrario ma consistente (AV calcola px = focal/sensorW*width)


def _file_index(path):
    """Estrae l'intero dal nome file (es. .../001.jpg -> 1)."""
    stem = Path(path).stem
    digits = "".join(ch for ch in stem if ch.isdigit())
    return int(digits) if digits else None


def inject(arg, cam_init_sfm, out_sfm):
    """Inietta pose + intrinseche ARKit in un cameraInit.sfm di AliceVision.
    Accoppia views<->foto per INDICE numerico nel nome file (i basename differiscono:
    001.jpg sul pod vs 0001.jpg nei metadati). Riscrive le intrinseche scalando i
    valori ARKit alla risoluzione reale dell'immagine letta da cameraInit."""
    src = SessionSource.open(arg)
    photos = sorted(src.photos, key=lambda p: int(p["order_index"]))
    # mappa: indice posizionale (1-based, come 001.jpg) -> metadata
    by_idx = {i + 1: p["metadata"] for i, p in enumerate(photos)}

    sfm = json.loads(Path(cam_init_sfm).read_text())
    views = sfm.get("views", [])
    intr_by_id = {it["intrinsicId"]: it for it in sfm.get("intrinsics", [])}

    poses = []
    matched = 0
    intr_done = set()
    for v in views:
        idx = _file_index(v["path"])
        meta = by_idx.get(idx)
        if meta is None:
            print(f"  ! nessun match (idx={idx}) per {Path(v['path']).name}")
            continue
        # --- POSA ---
        R_w2c, C = arkit_pose_to_av(meta["camera_transform"])
        rot = R_w2c.flatten(order="F")  # column-major
        poses.append({
            "poseId": v["poseId"],
            "pose": {"transform": {
                "rotation": [f"{x:.17g}" for x in rot],
                "center": [f"{x:.17g}" for x in C]},
                "locked": "1"},
        })
        # --- INTRINSECA (scala ARKit native -> dims reali del view) ---
        it = intr_by_id.get(v["intrinsicId"])
        if it is not None and v["intrinsicId"] not in intr_done:
            Wimg = float(it["width"]); Himg = float(it["height"])
            natW = float(meta["image_width"]); natH = float(meta["image_height"])
            s = Wimg / natW
            assert abs(Himg / natH - s) < 0.02, f"aspect mismatch {Wimg}x{Himg} vs {natW}x{natH}"
            fxn, fyn, cxn, cyn = intrinsics_fxfycxcy(meta["camera_intrinsics"])
            fx = fxn * s; fy = fyn * s; cx = cxn * s; cy = cyn * s
            focal_mm = fx / Wimg * SENSOR_W
            it["type"] = "pinhole"
            it["initializationMode"] = "calibrated"
            it["initialFocalLength"] = f"{focal_mm:.17g}"
            it["focalLength"] = f"{focal_mm:.17g}"
            it["sensorWidth"] = f"{SENSOR_W:.17g}"
            it["sensorHeight"] = f"{SENSOR_W * Himg / Wimg:.17g}"
            it["pixelRatio"] = f"{fy / fx:.17g}"
            it["pixelRatioLocked"] = "false"
            it["distortionParams"] = []
            it["principalPoint"] = [f"{cx - Wimg / 2:.17g}", f"{cy - Himg / 2:.17g}"]
            it["locked"] = "1"
            intr_done.add(v["intrinsicId"])
        matched += 1

    sfm["poses"] = poses
    Path(out_sfm).write_text(json.dumps(sfm, indent=2))
    print(f"iniettate {matched}/{len(views)} pose, {len(intr_done)} intrinseche -> {out_sfm}")


if __name__ == "__main__":
    arg = sys.argv[1]; raw = sys.argv[2:]
    if "--selftest" in raw:
        selftest(arg)
    elif "--inject" in raw:
        i = raw.index("--inject"); cam = raw[i + 1]
        j = raw.index("--out"); out = raw[j + 1]
        inject(arg, cam, out)
    else:
        print("usa --selftest  oppure  --inject cameraInit.sfm --out withPoses.sfm")
