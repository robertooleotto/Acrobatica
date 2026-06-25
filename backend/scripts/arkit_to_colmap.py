"""Esporta una sessione in formato COLMAP (sparse/0 + images/) per 2D Gaussian Splatting.

- foto -> images/<order_index>.jpg
- pose ARKit -> cameras.txt + images.txt (convenzione OpenCV/COLMAP, world->camera)
- init points3D.txt = nuvola Meshroom (cloud_and_poses.ply) riportata in scala ARKit
  via Umeyama (withPoses.sfm vs sfm.sfm), così sta nello STESSO frame delle pose.

Uso: python scripts/arkit_to_colmap.py 1553ab3c <sess_1553_dir> <out_dir>
"""
import sys, os, json, re
from pathlib import Path
import numpy as np, cv2
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))
from dotenv import load_dotenv; load_dotenv(ROOT / ".env")
from _session_source import SessionSource

FLIP = np.diag([1.0, -1.0, -1.0])  # OpenGL(ARKit) cam -> OpenCV(COLMAP) cam


def mat_colmajor(t):
    return np.array(t, float).reshape(4, 4, order="F")


def quat_from_R(R):
    # ritorna (qw,qx,qy,qz)
    t = np.trace(R)
    if t > 0:
        s = np.sqrt(t + 1.0) * 2; qw = 0.25 * s
        qx = (R[2, 1] - R[1, 2]) / s; qy = (R[0, 2] - R[2, 0]) / s; qz = (R[1, 0] - R[0, 1]) / s
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = np.sqrt(1 + R[0, 0] - R[1, 1] - R[2, 2]) * 2; qw = (R[2, 1] - R[1, 2]) / s
        qx = 0.25 * s; qy = (R[0, 1] + R[1, 0]) / s; qz = (R[0, 2] + R[2, 0]) / s
    elif R[1, 1] > R[2, 2]:
        s = np.sqrt(1 + R[1, 1] - R[0, 0] - R[2, 2]) * 2; qw = (R[0, 2] - R[2, 0]) / s
        qx = (R[0, 1] + R[1, 0]) / s; qy = 0.25 * s; qz = (R[1, 2] + R[2, 1]) / s
    else:
        s = np.sqrt(1 + R[2, 2] - R[0, 0] - R[1, 1]) * 2; qw = (R[1, 0] - R[0, 1]) / s
        qx = (R[0, 2] + R[2, 0]) / s; qy = (R[1, 2] + R[2, 1]) / s; qz = 0.25 * s
    q = np.array([qw, qx, qy, qz]); return q / np.linalg.norm(q)


def centers_by_view(sfm_path):
    d = json.load(open(sfm_path)); pose_c = {}
    for p in d.get("poses", []):
        pose_c[p["poseId"]] = np.array([float(x) for x in p["pose"]["transform"]["center"]])
    out = {}
    for v in d.get("views", []):
        if v.get("poseId") in pose_c:
            out[v["viewId"]] = (pose_c[v["poseId"]], int(re.search(r'(\d+)', v["path"].split("/")[-1]).group(1)))
    return out


def umeyama(src, dst):
    ms, md = src.mean(0), dst.mean(0); sc, dc = src - ms, dst - md
    H = sc.T @ dc / len(src); U, S, Vt = np.linalg.svd(H); d = np.sign(np.linalg.det(Vt.T @ U.T))
    R = Vt.T @ np.diag([1, 1, d]) @ U.T; s = (S * np.array([1, 1, d])).sum() / (sc ** 2).sum() * len(src)
    return s, R, md - s * R @ ms


def main(sid, sessdir, outdir):
    sessdir = Path(sessdir); out = Path(outdir)
    (out / "sparse" / "0").mkdir(parents=True, exist_ok=True)
    (out / "images").mkdir(parents=True, exist_ok=True)

    src = SessionSource.open(sid)
    photos = sorted(src.photos, key=lambda p: int(p["order_index"]))

    cam_lines, img_lines = [], []
    cam_lines.append("# Camera list")
    for i, p in enumerate(photos):
        oi = int(p["order_index"]); meta = p["metadata"]
        img = src.load_image(p)
        if img is None:
            continue
        h, w = img.shape[:2]
        mw, mh = int(meta["image_width"]), int(meta["image_height"])
        if (w, h) != (mw, mh) and (h, w) == (mw, mh):
            img = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE); h, w = img.shape[:2]
        name = f"{oi:04d}.jpg"
        cv2.imwrite(str(out / "images" / name), img)
        # intrinseci scalati a (w,h)
        K = np.array(meta["camera_intrinsics"], float).reshape(3, 3, order="F")
        sx = w / mw; sy = h / mh
        fx, fy = K[0, 0] * sx, K[1, 1] * sy; cx, cy = K[0, 2] * sx, K[1, 2] * sy
        cam_id = i + 1
        cam_lines.append(f"{cam_id} PINHOLE {w} {h} {fx:.4f} {fy:.4f} {cx:.4f} {cy:.4f}")
        # posa world->camera (OpenCV)
        T = mat_colmajor(meta["camera_transform"])
        R_c2w = T[:3, :3]; C = T[:3, 3]
        R_w2c = FLIP @ R_c2w.T
        t = -R_w2c @ C
        q = quat_from_R(R_w2c)
        img_lines.append(f"{cam_id} {q[0]:.9f} {q[1]:.9f} {q[2]:.9f} {q[3]:.9f} {t[0]:.6f} {t[1]:.6f} {t[2]:.6f} {cam_id} {name}")
        img_lines.append("")  # riga osservazioni 2D (vuota)

    open(out / "sparse" / "0" / "cameras.txt", "w").write("\n".join(cam_lines) + "\n")
    open(out / "sparse" / "0" / "images.txt", "w").write("\n".join(img_lines) + "\n")

    # points3D: cloud_and_poses.ply (Meshroom) -> scala ARKit via Umeyama
    s, R, t = (1.0, np.eye(3), np.zeros(3))
    wp = sessdir / "withPoses.sfm"; sf = sessdir / "sfm.sfm"
    if wp.exists() and sf.exists():
        ark = centers_by_view(str(wp)); est = centers_by_view(str(sf))
        common = sorted(set(ark) & set(est))
        A = np.array([ark[v][0] for v in common]); B = np.array([est[v][0] for v in common])
        s, R, t = umeyama(B, A)
        print(f"[colmap] Umeyama scala {s:.3f}x su {len(common)} camere")
    pts_lines = []
    ply = sessdir / "cloud_and_poses.ply"
    if ply.exists():
        P = []; C = []
        with open(ply) as f:
            hdr = True
            for line in f:
                if hdr:
                    if line.startswith("end_header"): hdr = False
                    continue
                a = line.split()
                if len(a) >= 6:
                    P.append([float(a[0]), float(a[1]), float(a[2])]); C.append([int(a[3]), int(a[4]), int(a[5])])
        P = np.array(P); C = np.array(C)
        green = (C[:, 0] == 0) & (C[:, 1] == 255) & (C[:, 2] == 0)
        P = P[~green]; C = C[~green]
        Pr = (s * (R @ P.T).T + t)
        for j, (pt, col) in enumerate(zip(Pr, C)):
            pts_lines.append(f"{j+1} {pt[0]:.6f} {pt[1]:.6f} {pt[2]:.6f} {col[0]} {col[1]} {col[2]} 0")
    open(out / "sparse" / "0" / "points3D.txt", "w").write("\n".join(pts_lines) + "\n")
    print(f"[colmap] scritto {len(img_lines)//2} immagini, {len(pts_lines)} punti init -> {out}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
