"""Ortorettifica di una foto di facciata su un piano del muro noto.

Dato:
  - piano del muro nello spazio mondo (normale + punto + assi right/up sul piano)
  - posa della camera (`camera_transform` 4×4) e intrinsics (`camera_intrinsics` 9
    floats col-major) di una foto ARKit
si calcola la 3×3 omografia che mappa coordinate-muro 2D `(u, v)` in pixel della
foto. Si inverte e si usa con `cv2.warpPerspective` per produrre l'immagine
ortografica della facciata vista perpendicolarmente al muro, con scala metrica
controllata da `pixels_per_meter`.

Per un piano, la math è una vera omografia (non rotation-only): funziona a
qualsiasi pitch della camera, anche estremo. È lo strumento giusto per il
rilievo facciate (orthorectification, standard topografico).

Limiti:
  - serve il piano. Lo si ottiene da `fit_plane_from_points` su >=3 punti 3D
    triangolati dai tap utente (`triangulation_service`) oppure dalla
    `wall_normal_world` di ARKit `.estimatedPlane`.
"""
from __future__ import annotations
import math
from dataclasses import dataclass, asdict
from typing import Optional

import cv2
import numpy as np


@dataclass(frozen=True)
class WallPlane:
    """Piano del muro in world coords, completo di basis 2D per il rendering ortho.

    `point`     : un punto sul piano (centroid dei punti di fit)
    `normal`    : normale unitaria al piano
    `right`     : asse orizzontale 3D sul piano (perpendicolare a normale e gravity)
    `up`        : asse verticale 3D sul piano (≈ world up proiettato sul piano)
    `u_min/max` : range del piano lungo `right` (metri), derivato dai punti di fit
    `v_min/max` : range del piano lungo `up`    (metri), idem
    """
    point:  tuple[float, float, float]
    normal: tuple[float, float, float]
    right:  tuple[float, float, float]
    up:     tuple[float, float, float]
    u_min: float; u_max: float
    v_min: float; v_max: float

    def width_m(self) -> float:  return self.u_max - self.u_min
    def height_m(self) -> float: return self.v_max - self.v_min

    def to_dict(self) -> dict:
        return asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "WallPlane":
        return WallPlane(
            point=tuple(d["point"]), normal=tuple(d["normal"]),
            right=tuple(d["right"]), up=tuple(d["up"]),
            u_min=float(d["u_min"]), u_max=float(d["u_max"]),
            v_min=float(d["v_min"]), v_max=float(d["v_max"]),
        )


# ──────────────────────────────────────────────────────────────────────────
# Fit del piano da N≥3 punti 3D coplanari (tipicamente i 4 angoli del muro
# triangolati da `triangulation_service.triangulate_rays`).
# ──────────────────────────────────────────────────────────────────────────

def fit_plane_from_points(
    points: list[tuple[float, float, float]],
    world_up: tuple[float, float, float] = (0.0, 1.0, 0.0),
    pad_m: float = 0.0,
    assume_vertical: bool = True,
    face_toward: tuple[float, float, float] | None = None,
) -> WallPlane:
    """Best-fit plane via SVD sui punti centrati. Calcola anche right/up assi 2D
    sul piano: `up` ≈ world_up proiettato (per facciate, ≈ verticale), `right` =
    cross(up, normal). I bounds `u_min/max, v_min/max` sono ricavati proiettando
    i punti di input sui due assi (più `pad_m` per margine).

    Se `assume_vertical=True` (default per rilievo facciate), la normale viene
    vincolata a essere ortogonale a `world_up` (= piano verticale). Questo evita
    fit sballati quando i punti triangolati sono concentrati in una piccola area
    e il rumore di triangolazione produce piani inclinati non realistici.

    Raises ValueError se < 3 punti.
    """
    arr = np.asarray(points, dtype=np.float64)
    if arr.shape[0] < 3:
        raise ValueError("fit_plane_from_points: servono almeno 3 punti")

    centroid = arr.mean(axis=0)
    centered = arr - centroid

    if assume_vertical:
        # Vincolo n_y = 0. Cerchiamo la normale solo nelle due direzioni
        # orizzontali (X, Z se world_up=Y). Costruiamo una matrice 2D coi punti
        # centrati proiettati sulle 2 direzioni orizzontali e facciamo SVD 2D.
        up_w = np.asarray(world_up, dtype=np.float64)
        up_w = up_w / np.linalg.norm(up_w)
        # Costruisci due assi orizzontali ortonormali (e1, e2)
        ref = np.array([1.0, 0.0, 0.0])
        if abs(np.dot(ref, up_w)) > 0.9:
            ref = np.array([0.0, 0.0, 1.0])
        e1 = ref - up_w * float(np.dot(ref, up_w))
        e1 = e1 / np.linalg.norm(e1)
        e2 = np.cross(up_w, e1)
        e2 = e2 / np.linalg.norm(e2)
        # Proietta i punti centrati sui due assi → matrice (N, 2)
        proj2 = np.column_stack([centered @ e1, centered @ e2])
        _, _, vh2 = np.linalg.svd(proj2, full_matrices=False)
        # Ultima riga di Vh2 = direzione di minima varianza nel piano orizzontale = normale 2D
        n2 = vh2[-1]
        # Ricostruisci la normale 3D
        normal = n2[0] * e1 + n2[1] * e2
        n_norm = np.linalg.norm(normal)
        if n_norm < 1e-6:
            raise ValueError("normale degenere")
        normal = normal / n_norm
    else:
        # Best-fit libero via SVD
        _, _, vh = np.linalg.svd(centered, full_matrices=False)
        normal = vh[-1]
        normal = normal / np.linalg.norm(normal)

    up_w = np.asarray(world_up, dtype=np.float64)
    # up_proj = up_w meno componente lungo normal
    up_proj = up_w - normal * float(np.dot(up_w, normal))
    n_up = np.linalg.norm(up_proj)
    if n_up < 1e-6:
        # piano orizzontale (parallelo a ground). Caso degenere: usa Z come fallback.
        up_proj = np.array([0.0, 0.0, 1.0]) - normal * float(normal[2])
        n_up = np.linalg.norm(up_proj)
        if n_up < 1e-6:
            raise ValueError("piano degenere")
    up_axis = up_proj / n_up

    # Orienta la normale verso `face_toward` (tipicamente la posizione media
    # delle camere). Evita l'ambiguità di segno del SVD che, se la normale
    # uscisse opposta alle camere, romperebbe il filtro `t > 0` delle
    # ray-plane intersections downstream e la proiezione ortografica.
    if face_toward is not None:
        target = np.asarray(face_toward, dtype=np.float64)
        if float(np.dot(normal, target - centroid)) < 0:
            normal = -normal

    right_axis = np.cross(up_axis, normal)
    right_axis = right_axis / np.linalg.norm(right_axis)

    us, vs = [], []
    for p in arr:
        d = p - centroid
        us.append(float(np.dot(d, right_axis)))
        vs.append(float(np.dot(d, up_axis)))

    return WallPlane(
        point=tuple(centroid.tolist()),
        normal=tuple(normal.tolist()),
        right=tuple(right_axis.tolist()),
        up=tuple(up_axis.tolist()),
        u_min=min(us) - pad_m, u_max=max(us) + pad_m,
        v_min=min(vs) - pad_m, v_max=max(vs) + pad_m,
    )


# ──────────────────────────────────────────────────────────────────────────
# Ortorettifica per-foto
# ──────────────────────────────────────────────────────────────────────────

def _intrinsics_K(K_col9: list[float] | tuple[float, ...]) -> np.ndarray:
    return np.array([
        [K_col9[0], 0.0,       K_col9[6]],
        [0.0,       K_col9[4], K_col9[7]],
        [0.0,       0.0,       1.0],
    ], dtype=np.float64)


@dataclass(frozen=True)
class OrthoInfo:
    pre_rotated_cw: bool
    output_size: tuple[int, int]   # (W, H) px
    pixels_per_meter: float
    homography_3x3: list[list[float]]


def orthorectify_photo(
    img: np.ndarray,
    intrinsics: list[float] | tuple[float, ...],
    camera_transform: list[float] | tuple[float, ...],
    plane: WallPlane,
    *,
    pixels_per_meter: float = 200.0,
    metadata_image_size: Optional[tuple[int, int]] = None,
    max_output_dim: int = 8000,
) -> tuple[np.ndarray, OrthoInfo]:
    """Proietta `img` (foto della facciata) sul piano del muro, ritornando
    un'immagine **ortografica** del muro a `pixels_per_meter` di risoluzione.

    Pre-rotazione del buffer (CW) automatica se il JPEG iOS è arrivato portrait
    mentre la K dichiara landscape (vedi `keystone_correction.py` per dettagli).
    """
    # 1) Allinea buffer ↔ K (stesso fix di keystone_correction.py)
    pre_rot = False
    if metadata_image_size is not None:
        meta_w, meta_h = int(metadata_image_size[0]), int(metadata_image_size[1])
        buf_h, buf_w = img.shape[:2]
        if (buf_w, buf_h) != (meta_w, meta_h) and (buf_h, buf_w) == (meta_w, meta_h):
            img = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
            pre_rot = True

    # 2) Pose della camera
    T = np.asarray(camera_transform, dtype=np.float64).reshape(4, 4, order="F")
    R_cam2world = T[:3, :3]
    cam_pos = T[:3, 3]
    R_world2cam = R_cam2world.T

    K = _intrinsics_K(intrinsics)
    fx, fy = K[0, 0], K[1, 1]
    cx, cy = K[0, 2], K[1, 2]

    # 3) Esprimo origine + assi del piano nel camera frame.
    O_w = np.asarray(plane.point,  dtype=np.float64) - cam_pos
    R_w = np.asarray(plane.right,  dtype=np.float64)
    U_w = np.asarray(plane.up,     dtype=np.float64)
    O_cam = R_world2cam @ O_w
    R_cam = R_world2cam @ R_w
    U_cam = R_world2cam @ U_w

    # 4) Omografia wall(u,v,1) → camera pixel (px,py,1). Derivazione:
    #    P_cam(u,v) = O_cam + u*R_cam + v*U_cam
    #    px = -fx*Xc/Zc + cx ;  py = +fy*Yc/Zc + cy   (ARKit camera frame, looks at -Z)
    #    Moltiplicando per Zc → mapping lineare in (u,v,1):
    H_wall_to_cam = np.array([
        [-fx * R_cam[0] + cx * R_cam[2], -fx * U_cam[0] + cx * U_cam[2], -fx * O_cam[0] + cx * O_cam[2]],
        [ fy * R_cam[1] + cy * R_cam[2],  fy * U_cam[1] + cy * U_cam[2],  fy * O_cam[1] + cy * O_cam[2]],
        [          R_cam[2],                       U_cam[2],                       O_cam[2]            ],
    ], dtype=np.float64)
    # Inversa: pixel della foto → (u,v,1) sul piano (per ogni pixel della foto, sapere a quale punto del muro corrisponde)
    H_cam_to_wall = np.linalg.inv(H_wall_to_cam)

    # 5) Dimensione output e affinità wall(u,v) → pixel output (top-left origin, v cresce in giù)
    u_min, u_max = plane.u_min, plane.u_max
    v_min, v_max = plane.v_min, plane.v_max
    out_w = int(math.ceil((u_max - u_min) * pixels_per_meter))
    out_h = int(math.ceil((v_max - v_min) * pixels_per_meter))

    # Clamp dimensione massima (mantiene proporzioni)
    if out_w > max_output_dim or out_h > max_output_dim:
        scale = max_output_dim / max(out_w, out_h)
        pixels_per_meter *= scale
        out_w = int(round(out_w * scale))
        out_h = int(round(out_h * scale))

    A_wall_to_pix = np.array([
        [pixels_per_meter, 0,                 -pixels_per_meter * u_min],
        [0,               -pixels_per_meter,   pixels_per_meter * v_max],
        [0,                0,                  1.0],
    ], dtype=np.float64)

    # 6) M finale che cv2 usa come forward (camera→output): cv2 inverte internamente.
    M = A_wall_to_pix @ H_cam_to_wall

    out = cv2.warpPerspective(
        img, M, (out_w, out_h),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0),
    )
    info = OrthoInfo(
        pre_rotated_cw=pre_rot,
        output_size=(out_w, out_h),
        pixels_per_meter=pixels_per_meter,
        homography_3x3=M.tolist(),
    )
    return out, info


def composite_orthos(orthos: list[np.ndarray], method: str = "best_source") -> np.ndarray:
    """Compone N immagini ortografiche dello STESSO piano in un panorama unico.

    Modalità:
      - "best_source" (default): per ogni pixel del panorama prende SOLO la foto
        dove quel pixel è più "centrale" nella sua zona di copertura (peso =
        distance transform della maschera). Niente media → niente ghosting da
        misalignment ARKit. Bordi tra foto hanno una transizione netta ma
        senza fantasmi.
      - "average": media pesata di tutte le foto che coprono un pixel. Più
        morbido ma soggetto a fantasmi quando le pose ARKit drift-ano.
    """
    if not orthos:
        raise ValueError("no orthos")
    H, W = orthos[0].shape[:2]
    for o in orthos:
        if o.shape[:2] != (H, W):
            raise ValueError("orthos non hanno tutte la stessa dimensione")
    stack = np.stack(orthos, axis=0).astype(np.float32)   # (N, H, W, 3)
    masks = (stack.sum(axis=-1) > 0).astype(np.uint8)     # (N, H, W)

    if method == "average":
        msum = masks[..., None]
        sums = (stack * msum).sum(axis=0)
        counts = msum.sum(axis=0).clip(min=1)
        return (sums / counts).astype(np.uint8)

    # best_source: per ogni foto, distance transform della sua maschera =
    # quanto è "interno" un pixel rispetto al bordo della copertura.
    # Argmax pixel-wise sui pesi → seleziona la foto migliore.
    weights = np.zeros((len(orthos), H, W), dtype=np.float32)
    for i, m in enumerate(masks):
        dt = cv2.distanceTransform(m, cv2.DIST_L2, 3)
        weights[i] = dt

    best = weights.argmax(axis=0)   # (H, W) indice della foto migliore per pixel
    any_cov = masks.any(axis=0)     # (H, W) c'è almeno una foto?
    out = np.zeros((H, W, 3), dtype=np.uint8)
    for i in range(len(orthos)):
        sel = (best == i) & any_cov & (masks[i].astype(bool))
        out[sel] = orthos[i][sel]
    return out
