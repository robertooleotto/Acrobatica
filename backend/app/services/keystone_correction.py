"""Keystone correction per-foto via pose ARKit.

L'utente inquadra un palazzo alto inclinando il telefono. Per ogni foto ARKit
ci dà il `camera_transform` 4×4 (camera→world). Applichiamo una **rotation-only
homography** che produce la foto "come se la camera fosse stata orientata in
modo neutro rispetto al muro".

Due modalità a seconda dei dati disponibili:

1. **Senza normale del muro** (`wall_normal_world=None`):
   virtual camera con `up = world_up`, `back = horizontal_projection(camera_back)`.
   Annulla **pitch e roll**, preserva lo **yaw** della camera. Le verticali tornano
   parallele; le orizzontali restano keystonate se la camera non era frontale al muro.

2. **Con normale del muro** (`wall_normal_world` da ARPlaneAnchor verticale):
   virtual camera con `up = world_up`, `back = -wall_normal_world_horizontal`.
   Annulla pitch, roll **e** lo yaw rispetto al muro. Verticali e orizzontali
   tornano parallele.

L'omografia applicata al buffer immagine è:
    H = K · R · K⁻¹
con R = R_world2virt · R_camera2world. K e R devono essere espresse nello stesso
frame del buffer immagine. iOS attualmente salva i JPEG portrait per via di
`UIImage(orientation: .right) + jpegData()` mentre K è calibrata sul buffer
landscape nativo ARKit; se rileviamo il mismatch, ruotiamo il buffer 90° CW
per riportarlo nel frame di K prima di applicare H.
"""
from __future__ import annotations
import math
from dataclasses import dataclass
from typing import Optional

import cv2
import numpy as np


@dataclass(frozen=True)
class KeystoneInfo:
    input_size: tuple[int, int]            # (W, H) buffer dopo pre-rotate
    output_size: tuple[int, int]           # (W, H) rectified
    pre_rotated_cw: bool                   # buffer ruotato 90° CW per allinearsi a K
    used_wall_normal: bool                 # virt camera back = -wall_normal vs horizontal cam_back
    homography_3x3: list[list[float]]


def _intrinsics_K(K_col_major: list[float] | tuple[float, ...]) -> np.ndarray:
    """Da col-major 9-float ARKit a matrice 3×3 standard image-coord."""
    return np.array([
        [K_col_major[0], 0,              K_col_major[6]],
        [0,              K_col_major[4], K_col_major[7]],
        [0,              0,              1.0],
    ], dtype=np.float64)


def _R_from_transform(
    camera_transform_col_major: list[float] | tuple[float, ...],
    wall_normal_world: Optional[list[float] | tuple[float, ...]] = None,
) -> tuple[np.ndarray, bool]:
    """Calcola R che porta da camera frame reale a un virtual frame "raddrizzato".

    Se `wall_normal_world` è dato, la virtual camera guarda perpendicolarmente al
    muro (back = -normale orizzontale): corregge anche le orizzontali. Altrimenti
    preserva lo yaw della camera reale.

    Ritorna (R, used_wall_normal).
    """
    T = np.array(camera_transform_col_major, dtype=np.float64).reshape(4, 4, order="F")
    R_cam2world = T[:3, :3]
    cam_back_w = R_cam2world[:, 2]   # camera looks -Z in camera frame → +Z col = back in world

    world_up = np.array([0.0, 1.0, 0.0])
    used_wall_normal = False

    if wall_normal_world is not None:
        n_w = np.array(wall_normal_world, dtype=np.float64)
        n_w[1] = 0.0  # proietta orizzontale (manteniamo virt camera level)
        nn = np.linalg.norm(n_w)
        if nn > 1e-6:
            n_w /= nn
            # Allinea la normale al lato giusto: deve puntare contro la camera.
            if float(np.dot(n_w, cam_back_w)) < 0:
                n_w = -n_w
            virt_back_w = n_w
            used_wall_normal = True

    if not used_wall_normal:
        virt_back_w = cam_back_w.copy()
        virt_back_w[1] = 0.0
        n = np.linalg.norm(virt_back_w)
        if n < 1e-6:
            virt_back_w = np.array([0.0, 0.0, 1.0])
        else:
            virt_back_w /= n

    virt_right_w = np.cross(world_up, virt_back_w)
    virt_right_w /= np.linalg.norm(virt_right_w)
    virt_up_w = np.cross(virt_back_w, virt_right_w)
    R_virt2world = np.column_stack([virt_right_w, virt_up_w, virt_back_w])

    R = R_virt2world.T @ R_cam2world
    return R, used_wall_normal


def _roll_deg_from_transform(camera_transform_col_major) -> float:
    """Angolo di roll del telefono = inclinazione di "world-up" nel piano
    immagine, in gradi. Positivo = phone inclinato a sinistra (world-up va
    verso destra dell'immagine)."""
    T = np.array(camera_transform_col_major, dtype=np.float64).reshape(4, 4, order="F")
    R = T[:3, :3]
    up_cam = R.T @ np.array([0.0, 1.0, 0.0])
    # Image plane: x right, y down. world-up direction in image = (up_cam.x, -up_cam.y).
    # Angle from "image-top" (which is direction (0,-1) in image coords) =
    #   atan2(image_x, -image_y) = atan2(up_cam.x, up_cam.y)
    return float(math.degrees(math.atan2(up_cam[0], up_cam[1])))


def _rotate_image_around_center(img: np.ndarray, deg: float) -> tuple[np.ndarray, np.ndarray]:
    """Ruota img di `deg` gradi (CCW positivo) attorno al centro immagine,
    espandendo il canvas per non perdere pixel. Restituisce (rotated, M_3x3)
    dove M_3x3 è la homography 3x3 equivalente all'affine usata."""
    h, w = img.shape[:2]
    cx, cy = w / 2.0, h / 2.0
    M2 = cv2.getRotationMatrix2D((cx, cy), deg, 1.0)
    cos_a, sin_a = abs(M2[0, 0]), abs(M2[0, 1])
    new_w = int(math.ceil(h * sin_a + w * cos_a))
    new_h = int(math.ceil(h * cos_a + w * sin_a))
    # Adatta la traslazione per centrare l'immagine ruotata nel nuovo canvas
    M2[0, 2] += (new_w / 2.0) - cx
    M2[1, 2] += (new_h / 2.0) - cy
    rotated = cv2.warpAffine(img, M2, (new_w, new_h),
                              flags=cv2.INTER_LINEAR,
                              borderMode=cv2.BORDER_CONSTANT,
                              borderValue=(0, 0, 0))
    M3 = np.vstack([M2, [0.0, 0.0, 1.0]])
    return rotated, M3


def keystone_correct(
    img: np.ndarray,
    intrinsics: list[float] | tuple[float, ...],
    camera_transform: list[float] | tuple[float, ...],
    *,
    wall_normal_world: Optional[list[float] | tuple[float, ...]] = None,
    metadata_image_size: Optional[tuple[int, int]] = None,
    max_output_dim: int = 6000,
    decompose_roll: bool = False,
) -> tuple[np.ndarray, KeystoneInfo]:
    """Restituisce (immagine_raddrizzata, info).

    Args:
      img: BGR HxW.
      intrinsics: 9-float col-major ARKit (`camera_intrinsics`).
      camera_transform: 16-float col-major ARKit (`camera_transform`, camera→world).
      wall_normal_world: opzionale, 3-float normale del muro in world. Se presente,
          corregge anche le orizzontali.
      metadata_image_size: (W,H) atteso del buffer secondo K (image_width,
          image_height da metadata). Se diverso dal buffer effettivo (caso iOS
          .right + jpegData → portrait), ruotiamo il buffer 90° CW per allinearsi.
    """
    K = _intrinsics_K(intrinsics)

    # Pre-rotate auto-detect: se il buffer non combacia con (image_width, image_height)
    # secondo metadata, ruotiamo CW (fix iOS UIImage .right baked-in).
    pre_rotated = False
    if metadata_image_size is not None:
        meta_w, meta_h = int(metadata_image_size[0]), int(metadata_image_size[1])
        buf_h, buf_w = img.shape[:2]
        if (buf_w, buf_h) != (meta_w, meta_h) and (buf_h, buf_w) == (meta_w, meta_h):
            img = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
            pre_rotated = True

    # Opzionale: decomponi roll dal pitch+yaw. Step 1: ruota in 2D l'immagine per
    # rimuovere il roll del telefono → output assi-allineato con la gravità.
    # Step 2: applica keystone con un transform "ripulito" dalla rotazione
    # attorno all'asse Z della camera. Risultato matematicamente equivalente al
    # single-pass ma con bbox finale più "naturale" (no parallelogrammi tilted
    # a pitch estremi).
    if decompose_roll:
        roll_deg = _roll_deg_from_transform(camera_transform)
        if abs(roll_deg) > 0.5:
            img, _ = _rotate_image_around_center(img, -roll_deg)
            # Aggiorna K coi nuovi cx, cy dovuti all'espansione canvas
            h_new, w_new = img.shape[:2]
            K = K.copy()
            K[0, 2] = w_new / 2.0   # cx → centro del nuovo canvas
            K[1, 2] = h_new / 2.0   # cy
            # Aggiorna camera_transform per togliere il roll: post-moltiplica
            # R_cam2world per R_z(+roll_rad) (rotazione attorno all'asse Z camera).
            roll_rad = math.radians(roll_deg)
            c, s = math.cos(roll_rad), math.sin(roll_rad)
            R_z_cam = np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], dtype=np.float64)
            T_old = np.array(camera_transform, dtype=np.float64).reshape(4, 4, order="F")
            R_old = T_old[:3, :3]
            R_new = R_old @ R_z_cam
            T_new = T_old.copy()
            T_new[:3, :3] = R_new
            camera_transform = T_new.flatten(order="F").tolist()

    R, used_wall_normal = _R_from_transform(camera_transform, wall_normal_world)

    h, w = img.shape[:2]
    Kinv = np.linalg.inv(K)
    H = K @ R @ Kinv

    # Bounding box dei 4 corner trasformati → trasla in coords positive (e scala se troppo grande).
    corners_h = np.array([[0,0,1],[w,0,1],[w,h,1],[0,h,1]], dtype=np.float64).T
    warped = H @ corners_h
    warped /= warped[2]
    xs, ys = warped[0], warped[1]
    xmin, xmax = float(xs.min()), float(xs.max())
    ymin, ymax = float(ys.min()), float(ys.max())
    out_w = int(math.ceil(xmax - xmin))
    out_h = int(math.ceil(ymax - ymin))

    scale = 1.0
    if out_w > max_output_dim or out_h > max_output_dim:
        scale = max_output_dim / max(out_w, out_h)
        out_w = int(round(out_w * scale))
        out_h = int(round(out_h * scale))
    T_aff = np.array([
        [scale, 0,     -xmin * scale],
        [0,     scale, -ymin * scale],
        [0,     0,      1.0],
    ], dtype=np.float64)
    H_final = T_aff @ H

    out = cv2.warpPerspective(img, H_final, (out_w, out_h),
                              flags=cv2.INTER_LINEAR,
                              borderMode=cv2.BORDER_CONSTANT,
                              borderValue=(0, 0, 0))

    info = KeystoneInfo(
        input_size=(w, h),
        output_size=(out_w, out_h),
        pre_rotated_cw=pre_rotated,
        used_wall_normal=used_wall_normal,
        homography_3x3=H_final.tolist(),
    )
    return out, info
