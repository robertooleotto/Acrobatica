"""4-tap interattivo locale: apre 2+ foto di una fixture in finestre OpenCV,
ci clicchi sopra i 4 angoli del muro nello stesso ordine (TL → TR → BR → BL),
e lo script triangola, fitta il piano, ortorettifica tutta la sessione, fa il
composite per fasce e apre il risultato in Preview.

Uso:
    python scripts/tap4_local.py <fixture_dir> [order_idx_a order_idx_b ...]

Esempio:
    python scripts/tap4_local.py data/fixtures/a8b096e3 0 6
    python scripts/tap4_local.py data/fixtures/a8b096e3            # auto = prima e mediana

Controlli nella finestra OpenCV:
    click sinistro     → piazza un marker (in ordine TL → TR → BR → BL)
    z / BACKSPACE      → annulla l'ultimo tap
    r                  → restart su questa foto
    INVIO / SPACE      → conferma e passa alla foto successiva
    q / ESC            → annulla tutto
"""
from __future__ import annotations
import sys, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

import cv2
import numpy as np
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")

from app.services import triangulation_service
from app.services.triangulation_service import CameraPose, Point3D
from app.services.orthorectify_service import (
    fit_plane_from_points, orthorectify_photo, composite_orthos, WallPlane,
)
from _session_source import SessionSource


CORNER_NAMES = ["TL", "TR", "BR", "BL"]
CORNER_COLORS = [(0, 255, 255), (0, 200, 0), (0, 100, 255), (255, 0, 200)]  # BGR


def landscape_aligned(img: np.ndarray, meta: dict) -> np.ndarray:
    h, w = img.shape[:2]
    if (w, h) != (int(meta["image_width"]), int(meta["image_height"])):
        if (h, w) == (int(meta["image_width"]), int(meta["image_height"])):
            return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    return img


def world_up_angle_in_image(camera_transform: list[float]) -> float:
    """Angolo (gradi) della direzione 'mondo-su' proiettata sull'immagine
    landscape native, dove y dell'immagine cresce verso il basso.
        0   → mondo-su punta verso il TOP dell'immagine (già dritta)
       180  → mondo-su punta verso il BOTTOM (immagine sottosopra)
       +90  → mondo-su punta verso DESTRA
       -90  → mondo-su punta verso SINISTRA
    """
    T = np.asarray(camera_transform, dtype=np.float64).reshape(4, 4, order="F")
    R = T[:3, :3]
    up_cam = R.T @ np.array([0.0, 1.0, 0.0])
    # Camera frame: +x destra (= +x immagine), +y su (= -y immagine)
    # Vogliamo l'angolo del vettore world-up in image-coords (x_right, y_down)
    # rispetto alla direzione "image-top" (0, -1). L'image-top direction in
    # camera-frame è (0, +1) (camera +y = immagine up = -y image). Quindi:
    #   image_x = up_cam.x,  image_y = -up_cam.y
    #   angle dal-top = atan2(image_x, -image_y) = atan2(up_cam.x, up_cam.y)
    return float(np.degrees(np.arctan2(up_cam[0], up_cam[1])))


def choose_display_rotation(angle_deg: float):
    """Ritorna (cv2_rotation_code, label) per allineare il display al mondo-su.
    None = niente rotazione."""
    if -45 <= angle_deg <= 45:
        return (None, "0°")
    elif 45 < angle_deg <= 135:
        return (cv2.ROTATE_90_CLOCKWISE, "90° CW")
    elif -135 <= angle_deg < -45:
        return (cv2.ROTATE_90_COUNTERCLOCKWISE, "90° CCW")
    else:
        return (cv2.ROTATE_180, "180°")


def display_to_native(xd: float, yd: float,
                      native_w: int, native_h: int,
                      rotation_code) -> tuple[float, float]:
    """Inverte la cv2.rotate applicata al display.

    Ricava le coords nel buffer NATIVO (landscape ARKit, w×h originale).
    """
    if rotation_code is None:
        return (xd, yd)
    if rotation_code == cv2.ROTATE_90_CLOCKWISE:
        # display = h×w (swapped); native (x,y) → display (h-1-y, x)
        return (yd, native_h - 1 - xd)
    if rotation_code == cv2.ROTATE_90_COUNTERCLOCKWISE:
        return (native_w - 1 - yd, xd)
    if rotation_code == cv2.ROTATE_180:
        return (native_w - 1 - xd, native_h - 1 - yd)
    return (xd, yd)


def pick_4_corners(img_native: np.ndarray, label: str,
                    camera_transform: list[float]) -> list[tuple[float, float]] | None:
    """Apre una finestra OpenCV, l'utente clicca 4 corner. Ritorna coords in
    pixel del frame NATIVO (non lo scaled display). Ruota automaticamente il
    display in modo che il "mondo-su" sia in alto."""
    native_h, native_w = img_native.shape[:2]
    # Auto-raddrizza il display in base a come era tenuto il telefono.
    angle = world_up_angle_in_image(camera_transform)
    rot_code, rot_label = choose_display_rotation(angle)
    rotated = img_native if rot_code is None else cv2.rotate(img_native, rot_code)
    print(f"  world-up angle in image = {angle:+.0f}° → display rotato {rot_label}")

    # Display scale (sul rotato, che può avere dimensioni diverse)
    target_w = 1400
    scale = min(target_w / rotated.shape[1], 900 / rotated.shape[0], 1.0)
    disp_w = int(rotated.shape[1] * scale)
    disp_h = int(rotated.shape[0] * scale)
    disp = cv2.resize(rotated, (disp_w, disp_h), interpolation=cv2.INTER_AREA) if scale < 1 else rotated.copy()
    base = disp.copy()

    taps: list[tuple[int, int]] = []   # display pixels

    win = f"4-tap [{label}]  click TL,TR,BR,BL  z=undo  ENTER=conferma  q=esci"
    cv2.namedWindow(win, cv2.WINDOW_AUTOSIZE)

    def on_mouse(event, x, y, flags, p):
        nonlocal taps
        if event == cv2.EVENT_LBUTTONDOWN and len(taps) < 4:
            taps.append((x, y))

    cv2.setMouseCallback(win, on_mouse)

    while True:
        vis = base.copy()
        for i, (x, y) in enumerate(taps):
            c = CORNER_COLORS[i]
            cv2.circle(vis, (x, y), 14, c, 2)
            cv2.circle(vis, (x, y), 4, c, -1)
            cv2.putText(vis, CORNER_NAMES[i], (x + 16, y - 6),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, c, 2)
        # banner
        if len(taps) < 4:
            msg = f"Clicca {CORNER_NAMES[len(taps)]} ({len(taps)+1}/4)"
            color = (40, 200, 255)
        else:
            msg = "OK — premi ENTER per confermare, z=undo, r=reset"
            color = (50, 220, 50)
        cv2.rectangle(vis, (0, 0), (disp_w, 36), (0, 0, 0), -1)
        cv2.putText(vis, msg, (12, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2)

        cv2.imshow(win, vis)
        key = cv2.waitKey(20) & 0xFF
        if key in (13, 10) and len(taps) == 4:        # INVIO
            break
        if key == 32 and len(taps) == 4:               # SPACE
            break
        if key in (8, ord("z"), 127):                  # backspace / z / DEL
            if taps: taps.pop()
        if key == ord("r"):
            taps.clear()
        if key in (27, ord("q")):                      # ESC / q
            cv2.destroyWindow(win)
            return None

    cv2.destroyWindow(win)
    if len(taps) != 4: return None
    # Step 1: display → rotated-coords (unscale)
    inv = 1.0 / scale
    in_rotated = [(x * inv, y * inv) for (x, y) in taps]
    # Step 2: rotated-coords → native landscape ARKit coords (inversa della rotate)
    return [display_to_native(xr, yr, native_w, native_h, rot_code)
            for (xr, yr) in in_rotated]


def pose_from(meta: dict) -> CameraPose:
    return CameraPose(transform=tuple(meta["camera_transform"]),
                      intrinsics=tuple(meta["camera_intrinsics"]))


def main(fixture_arg: str, orders: list[int]) -> None:
    src = SessionSource.open(fixture_arg)
    print(f"Sessione: {src.source_label}  ({len(src.photos)} foto)")

    # Mappa order_index → photo + img
    photos = {p["order_index"]: p for p in src.photos}
    if not orders:
        # default: prima e mediana
        idxs = sorted(photos.keys())
        orders = [idxs[0], idxs[len(idxs) // 2]]
    print(f"Foto per il 4-tap: {orders}")

    images: dict[int, np.ndarray] = {}
    for idx in orders:
        if idx not in photos:
            raise SystemExit(f"order_index {idx} non trovato")
        img = src.load_image(photos[idx])
        if img is None:
            raise SystemExit(f"decode fallito foto {idx}")
        images[idx] = landscape_aligned(img, photos[idx]["metadata"])

    # Apri ogni foto e raccogli i 4 tap. taps_per_photo[order_idx] = [(x_native, y_native)*4]
    taps_per_photo: dict[int, list[tuple[float, float]]] = {}
    for idx in orders:
        print(f"\n→ Foto {idx}: clicca i 4 angoli TL, TR, BR, BL del muro")
        taps = pick_4_corners(images[idx], f"foto {idx}",
                              photos[idx]["metadata"]["camera_transform"])
        if taps is None:
            raise SystemExit("Annullato.")
        taps_per_photo[idx] = taps
        for i, (x, y) in enumerate(taps):
            print(f"  {CORNER_NAMES[i]}: ({x:.0f}, {y:.0f}) px native")

    # Triangola ogni corner usando i tap su tutte le foto
    print("\nTriangolazione 4 angoli…")
    corners_3d: list[Point3D] = []
    for ci, cname in enumerate(CORNER_NAMES):
        rays = []
        for idx in orders:
            xp, yp = taps_per_photo[idx][ci]
            pose = pose_from(photos[idx]["metadata"])
            rays.append(triangulation_service.ray_from_pixel(pose, xp, yp))
        p3 = triangulation_service.triangulate_rays(rays)
        if p3 is None:
            raise SystemExit(f"triangolazione {cname} fallita")
        print(f"  {cname}: 3D = ({p3.x:+.2f}, {p3.y:+.2f}, {p3.z:+.2f})")
        corners_3d.append(p3)

    # Fit del piano
    pts = [(c.x, c.y, c.z) for c in corners_3d]
    plane = fit_plane_from_points(pts, pad_m=0.0, assume_vertical=True)
    print(f"\npiano: normale={tuple(round(x,3) for x in plane.normal)}")
    print(f"        bounds 4-tap u=[{plane.u_min:.2f},{plane.u_max:.2f}]  "
          f"v=[{plane.v_min:.2f},{plane.v_max:.2f}]")

    # Estendi i bounds proiettando i FOV di TUTTE le foto sul piano (vedi
    # run_ortho_local.py per logica). Riusiamo qui inline per semplicità.
    centroid = np.array(plane.point); n = np.array(plane.normal)
    r_axis = np.array(plane.right); u_axis = np.array(plane.up)
    us, vs = [], []
    accepted = rejected_denom = rejected_t = rejected_dist = 0
    for p in src.photos:
        m = p["metadata"]
        W, H = int(m["image_width"]), int(m["image_height"])
        pose = pose_from(m)
        for (x, y) in [(W/2, H/2), (0, 0), (W-1, 0), (W-1, H-1), (0, H-1)]:
            ray = triangulation_service.ray_from_pixel(pose, float(x), float(y))
            o = np.array([ray.origin.x, ray.origin.y, ray.origin.z])
            d = np.array([ray.direction.x, ray.direction.y, ray.direction.z])
            denom = float(np.dot(d, n))
            if abs(denom) < 0.10:  rejected_denom += 1; continue
            t = float(np.dot(centroid - o, n)) / denom
            if t <= 0 or t > 30:   rejected_t += 1; continue
            P = o + t * d
            d2c = P - centroid
            up = float(np.dot(d2c, r_axis)); vp = float(np.dot(d2c, u_axis))
            if abs(up) > 15 or abs(vp) > 15: rejected_dist += 1; continue
            us.append(up); vs.append(vp)
            accepted += 1
    print(f"        FOV-projection: {accepted} accettati, "
          f"rejected: denom={rejected_denom}, t={rejected_t}, dist={rejected_dist}")
    if us:
        u_lo, u_hi = np.percentile(us, [2, 98])
        v_lo, v_hi = np.percentile(vs, [2, 98])
        # UNIONE: estendi bounds esistenti coi FOV. Non sostituire — il 4-tap
        # potrebbe coprire zone NON viste dai FOV (es. angolo nascosto).
        pad = 0.3
        new_u_min = min(plane.u_min, float(u_lo)) - pad
        new_u_max = max(plane.u_max, float(u_hi)) + pad
        new_v_min = min(plane.v_min, float(v_lo)) - pad
        new_v_max = max(plane.v_max, float(v_hi)) + pad
        plane = WallPlane(
            point=plane.point, normal=plane.normal, right=plane.right, up=plane.up,
            u_min=new_u_min, u_max=new_u_max,
            v_min=new_v_min, v_max=new_v_max,
        )
    print(f"        bounds estesi u=[{plane.u_min:.2f},{plane.u_max:.2f}]  "
          f"v=[{plane.v_min:.2f},{plane.v_max:.2f}]  "
          f"({plane.width_m():.1f}m × {plane.height_m():.1f}m)")

    # Ortografica tutte le foto + composite per fascia + finale
    out_dir = Path(f"/tmp/ortho4tap_{src.sid[:8]}")
    out_dir.mkdir(parents=True, exist_ok=True)
    orthos_by_idx: dict[int, np.ndarray] = {}
    paths: list[Path] = []
    for p in src.photos:
        img = src.load_image(p)
        if img is None: continue
        try:
            ortho, info = orthorectify_photo(
                img, intrinsics=p["metadata"]["camera_intrinsics"],
                camera_transform=p["metadata"]["camera_transform"],
                plane=plane, pixels_per_meter=150,
                metadata_image_size=(int(p["metadata"]["image_width"]),
                                     int(p["metadata"]["image_height"])),
            )
        except Exception as e:
            print(f"  [{p['order_index']}] ortho fallito: {e}"); continue
        path = out_dir / f"{p['order_index']:02d}_ortho.jpg"
        cv2.imwrite(str(path), ortho, [cv2.IMWRITE_JPEG_QUALITY, 88])
        orthos_by_idx[p["order_index"]] = ortho
        paths.append(path)

    # Cluster per fascia (stessa logica di run_ortho_local.py)
    def camera_xz(meta: dict) -> tuple[float, float]:
        T = np.asarray(meta["camera_transform"], dtype=np.float64).reshape(4,4,order="F")
        return float(T[0,3]), float(T[2,3])
    clusters: list[list[dict]] = []
    cur: list[dict] = []
    cur_centroid: tuple[float, float] | None = None
    SOGLIA = 0.5
    for p in sorted(src.photos, key=lambda x: x["order_index"]):
        if p["order_index"] not in orthos_by_idx: continue
        x, z = camera_xz(p["metadata"])
        if cur_centroid is None: cur.append(p); cur_centroid = (x, z)
        else:
            cx, cz = cur_centroid
            if ((x-cx)**2 + (z-cz)**2)**0.5 <= SOGLIA:
                cur.append(p)
                n_ = len(cur); cur_centroid = (cx + (x-cx)/n_, cz + (z-cz)/n_)
            else:
                clusters.append(cur); cur = [p]; cur_centroid = (x, z)
    if cur: clusters.append(cur)
    print(f"\nFasce verticali: {len(clusters)}")
    fascia_composites: list[np.ndarray] = []
    for i, cluster in enumerate(clusters):
        os_ = [orthos_by_idx[p["order_index"]] for p in cluster]
        fc = os_[0] if len(os_) == 1 else composite_orthos(os_, method="best_source")
        fc_path = out_dir / f"fascia_{i+1:02d}.jpg"
        cv2.imwrite(str(fc_path), fc, [cv2.IMWRITE_JPEG_QUALITY, 90])
        fascia_composites.append(fc)
        paths.insert(0, fc_path)
        print(f"  fascia {i+1}: {len(cluster)} foto → {fc_path.name}")

    if len(fascia_composites) >= 2:
        final = composite_orthos(fascia_composites, method="best_source")
        final_path = out_dir / "00_composite_final.jpg"
        cv2.imwrite(str(final_path), final, [cv2.IMWRITE_JPEG_QUALITY, 90])
        print(f"\nComposite FINALE: {final_path}  ({final.shape[1]}×{final.shape[0]})")
        paths.insert(0, final_path)

    print(f"\nApro {len(paths)} immagini in Preview…")
    subprocess.run(["open", "-a", "Preview", *[str(p) for p in paths]], check=False)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Uso: python scripts/tap4_local.py <fixture_dir> [order_a order_b ...]")
    fixture = sys.argv[1]
    orders = [int(x) for x in sys.argv[2:]]
    main(fixture, orders)
