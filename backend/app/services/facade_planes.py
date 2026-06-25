"""Rilevamento automatico dei piani di facciata da foto + pose ARKit.

Sostituisce il flusso manuale "4-tap": invece di chiedere all'operatore di
indicare gli angoli del muro, triangoliamo una nuvola di punti fotografica
(SIFT + filtro epipolare dalle pose note) e ci facciamo RANSAC sequenziale
di piani quasi verticali. Nessuna mesh Object Capture, nessun bridge Umeyama:
servono SOLO le foto e i metadata ARKit (photos.json).

Convenzione pose (vedi anche `orthorectify_service`/`keystone_correction`):
  T = reshape(camera_transform, (4,4), order="F");  C = T[:3,3];  R = T[:3,:3]
  proiezione: rel = X - C;  cxyz = rel @ R;  z davanti NEGATIVA;
  px = -fx*x/z + cx ;  py = fy*y/z + cy
Internamente convertiamo alla convenzione OpenCV standard:
  Xc_std = D @ R.T @ (X - C), con D = diag(1,-1,-1)  →  R_cv = D R^T, t_cv = -R_cv C

Punti chiave del metodo:
  - le coppie stereo si scelgono per baseline 0.5–4 m e assi ottici < 30°;
  - il filtro dei match è SEMPRE la geometria epipolare derivata dalle POSE
    (mai stimare F dai match: le facciate hanno pattern ripetitivi e RANSAC
    su F converge su omografie sbagliate);
  - i riflessi nei vetri triangolano un "muro fantasma" planare 1.5–3 m
    DIETRO la facciata: lo eliminiamo confrontando coppie di piani paralleli
    e scartando quello più arretrato rispetto alle camere (vedi
    la verifica fotometrica `verify_planes_photometric`).

Output serializzabile JSON, stesso formato del piano "4-tap"
(c, n, up, right, bounds) + campi extra (n_inliers, rms_cm, area_m2).
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Sequence, Union

import cv2
import numpy as np

# diag(1,-1,-1): ribalta Y e Z per passare da ARKit (y su, z dietro) a OpenCV
_D = np.diag([1.0, -1.0, -1.0])

# ── Parametri di default (validati sulla sessione 6cdcb8ff) ─────────────────
# triangolazione
DEFAULT_SCALE = 0.5          # detection a mezza risoluzione (coords riportate a full-res)
DEFAULT_NFEATURES = 3000
RATIO_TEST = 0.8
EPI_THRESH_PX = 2.0          # distanza epipolare simmetrica max (full-res)
MIN_BASELINE_M, MAX_BASELINE_M = 0.5, 4.0
PREFERRED_BASELINE_M = 1.5
MAX_OPTICAL_ANGLE_DEG = 30.0
MAX_PAIRS_PER_CAMERA = 6
MIN_PARALLAX_DEG = 2.0
MAX_REPROJ_PX = 2.0
Y_MIN_M, Y_MAX_M = -2.0, 25.0   # quota plausibile per punti di facciata
MAX_TRACK_LEN = 12
# RANSAC piani
PLANE_DIST_THRESH_M = 0.04
MAX_NORMAL_UP_DOT = 0.10     # |n·up| max: piano quasi verticale
MIN_PLANE_INLIERS = 250
MAX_PLANES = 5
RANSAC_ITERS = 4000
# filtro muro-fantasma / dedup
DEDUP_ANGLE_DEG = 3.0
DEDUP_DIST_M = 0.30
GHOST_ANGLE_DEG = 12.0
GHOST_MIN_GAP_M = 0.5
GHOST_MAX_GAP_M = 6.0
DOMINANT_FACADE_DIST_THRESH_M = 0.15
DOMINANT_FACADE_PAD_M = 0.30


# ──────────────────────────────────────────────────────────────────────────
# Strutture dati
# ──────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class CameraView:
    """Posa + intrinsics di una foto, già convertita in convenzione OpenCV."""
    order_index: int
    path: Path
    K: np.ndarray        # 3x3
    C: np.ndarray        # centro camera (world)
    R_cv: np.ndarray     # 3x3 world→camera (OpenCV)
    t_cv: np.ndarray     # 3
    P: np.ndarray        # 3x4 matrice di proiezione
    fwd: np.ndarray      # asse ottico in world (verso di vista)


@dataclass
class TriangulatedCloud:
    """Nuvola di punti triangolata da una sessione."""
    points: np.ndarray           # (N,3) world ARKit, metrico
    n_obs: np.ndarray            # (N,) osservazioni per punto
    rms_px: np.ndarray           # (N,) RMS riproiezione per punto
    camera_centers: np.ndarray   # (M,3) centri delle camere usate
    feature_kind: str            # "SIFT" | "ORB"
    n_pairs: int
    elapsed_s: float

    def save_npz(self, path: Union[str, Path]) -> None:
        """Salva la nuvola come .npz (niente PLY: open3d non è nel backend)."""
        np.savez(path, points=self.points, n_obs=self.n_obs, rms=self.rms_px,
                 camera_centers=self.camera_centers)


@dataclass
class FacadePlane:
    """Piano di facciata rilevato. Stesso frame del piano 4-tap:

    `c`      : punto sul piano (centroide degli inlier)
    `n`      : normale unitaria, orientata VERSO le camere
    `up`     : gravità proiettata sul piano (≈ (0,1,0))
    `right`  : up × n (asse orizzontale sul piano)
    `bounds` : [u_min, u_max, v_min, v_max] in metri lungo right/up,
               percentili 1–99 degli inlier rispetto a `c`
    """
    c: np.ndarray
    n: np.ndarray
    up: np.ndarray
    right: np.ndarray
    bounds: tuple[float, float, float, float]
    n_inliers: int
    rms_m: float
    inlier_mask: np.ndarray = field(repr=False)
    # campione degli inlier 3D (max ~2000): serve al test di attraversamento
    # del filtro muro-fantasma
    sample_pts: np.ndarray = field(default=None, repr=False)
    # NCC mutua delle foto proiettate sul piano (verifica fotometrica):
    # alto = muro vero, basso = piano da match finestra-sbagliata
    photo_score: float = 0.0

    @property
    def width_m(self) -> float:
        return self.bounds[1] - self.bounds[0]

    @property
    def height_m(self) -> float:
        return self.bounds[3] - self.bounds[2]

    @property
    def area_m2(self) -> float:
        return self.width_m * self.height_m

    def to_dict(self) -> dict:
        """Formato compatibile con true_plane.json + campi extra."""
        return {
            "c": [float(v) for v in self.c],
            "n": [float(v) for v in self.n],
            "up": [float(v) for v in self.up],
            "right": [float(v) for v in self.right],
            "bounds": [float(v) for v in self.bounds],
            "n_inliers": int(self.n_inliers),
            "rms_cm": float(self.rms_m * 100.0),
            "area_m2": float(self.area_m2),
            "photo_score": float(self.photo_score),
        }


# ──────────────────────────────────────────────────────────────────────────
# Caricamento camere
# ──────────────────────────────────────────────────────────────────────────

def load_cameras(
    photos_dir: Union[str, Path],
    photos_json: Union[str, Path, Sequence[dict]],
) -> list[CameraView]:
    """Costruisce le `CameraView` da photos.json (path o lista già caricata).

    Ogni elemento deve avere `metadata.camera_transform` (16 float col-major),
    `metadata.camera_intrinsics` (9 float col-major) e `storage_path` (o
    `local_path`) per risolvere il file immagine dentro `photos_dir`.
    """
    photos_dir = Path(photos_dir)
    if isinstance(photos_json, (str, Path)):
        data = json.loads(Path(photos_json).read_text())
    else:
        data = list(photos_json)

    cams: list[CameraView] = []
    for ph in data:
        m = ph.get("metadata", ph)  # accetta anche metadata "piatti"
        T = np.asarray(m["camera_transform"], dtype=np.float64).reshape(4, 4, order="F")
        K9 = m["camera_intrinsics"]
        K = np.array([[K9[0], 0.0, K9[6]],
                      [0.0, K9[4], K9[7]],
                      [0.0, 0.0, 1.0]], dtype=np.float64)
        R = T[:3, :3]
        C = T[:3, 3]
        R_cv = _D @ R.T
        t_cv = -R_cv @ C
        name = Path(ph.get("local_path") or ph["storage_path"]).name
        cams.append(CameraView(
            order_index=int(m.get("order_index", len(cams))),
            path=photos_dir / name,
            K=K, C=C, R_cv=R_cv, t_cv=t_cv,
            P=K @ np.hstack([R_cv, t_cv[:, None]]),
            fwd=-R[:, 2],
        ))
    cams.sort(key=lambda c: c.order_index)
    return cams


# ──────────────────────────────────────────────────────────────────────────
# Triangolazione
# ──────────────────────────────────────────────────────────────────────────

def _select_pairs(cams: list[CameraView]) -> list[tuple[int, int]]:
    """Coppie stereo: baseline 0.5–4 m, assi ottici < 30°, max 6 per camera,
    preferendo baseline ~1.5 m (compromesso parallasse/overlap)."""
    Cs = np.array([c.C for c in cams])
    Fs = np.array([c.fwd for c in cams])
    cos_max = np.cos(np.radians(MAX_OPTICAL_ANGLE_DEG))
    pairs: set[tuple[int, int]] = set()
    for a in range(len(cams)):
        d = np.linalg.norm(Cs - Cs[a], axis=1)
        ang_ok = (Fs @ Fs[a]) > cos_max
        cand = np.where((d > MIN_BASELINE_M) & (d < MAX_BASELINE_M) & ang_ok)[0]
        cand = cand[cand > a]  # solo in avanti, evita duplicati
        if len(cand) == 0:
            continue
        score = np.abs(d[cand] - PREFERRED_BASELINE_M)
        for b in cand[np.argsort(score)][:MAX_PAIRS_PER_CAMERA]:
            pairs.add((a, int(b)))
    return sorted(pairs)


def _fundamental_from_poses(c1: CameraView, c2: CameraView) -> np.ndarray:
    """F derivata dalle pose note (MAI stimata dai match: pattern ripetitivi)."""
    R_rel = c2.R_cv @ c1.R_cv.T
    t_rel = c2.t_cv - R_rel @ c1.t_cv
    tx = np.array([[0, -t_rel[2], t_rel[1]],
                   [t_rel[2], 0, -t_rel[0]],
                   [-t_rel[1], t_rel[0], 0]])
    E = tx @ R_rel
    return np.linalg.inv(c2.K).T @ E @ np.linalg.inv(c1.K)


def _epipolar_dist(F: np.ndarray, p1: np.ndarray, p2: np.ndarray) -> np.ndarray:
    """Distanza epipolare simmetrica (max delle due direzioni), in px."""
    h1 = np.hstack([p1, np.ones((len(p1), 1))])
    h2 = np.hstack([p2, np.ones((len(p2), 1))])
    l2 = h1 @ F.T   # linee in img2
    l1 = h2 @ F     # linee in img1
    d2 = np.abs(np.sum(l2 * h2, axis=1)) / np.hypot(l2[:, 0], l2[:, 1])
    d1 = np.abs(np.sum(l1 * h1, axis=1)) / np.hypot(l1[:, 0], l1[:, 1])
    return np.maximum(d1, d2)


class _UnionFind:
    """Union-find per fondere i match pairwise in tracce multi-vista."""

    def __init__(self) -> None:
        self.parent: dict = {}

    def find(self, x):
        p = self.parent
        while p.setdefault(x, x) != x:
            p[x] = p[p[x]]
            x = p[x]
        return x

    def union(self, a, b) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[ra] = rb


def _create_detector(nfeatures: int):
    """SIFT se disponibile, altrimenti ORB (opencv-headless senza contrib)."""
    if hasattr(cv2, "SIFT_create"):
        return cv2.SIFT_create(nfeatures=nfeatures), "SIFT"
    return cv2.ORB_create(nfeatures=nfeatures * 2), "ORB"


def triangulate_session(
    photos_dir: Union[str, Path],
    photos_json: Union[str, Path, Sequence[dict]],
    *,
    step: int = 1,
    scale: float = DEFAULT_SCALE,
    nfeatures: int = DEFAULT_NFEATURES,
    progress: bool = False,
) -> TriangulatedCloud:
    """Triangola una nuvola di punti dalla sessione (solo foto + pose ARKit).

    Pipeline: selezione coppie → feature (SIFT/ORB) + ratio test → filtro
    epipolare dalle pose → tracce multi-vista (union-find) → DLT multi-vista →
    filtri qualità (davanti a tutte le camere, riproiezione < 2 px, parallasse
    > 2°, quota −2..+25 m).

    `step` usa una foto ogni `step` (per test rapidi); `scale` riduce la
    risoluzione di detection (le coordinate sono riportate a full-res).
    """
    t0 = time.time()
    cams = load_cameras(photos_dir, photos_json)
    cams = cams[::max(1, int(step))]
    if len(cams) < 2:
        raise ValueError("triangulate_session: servono almeno 2 foto con posa")

    pairs = _select_pairs(cams)
    detector, kind = _create_detector(nfeatures)
    binary_desc = kind == "ORB"

    # 1) feature per ogni foto (a risoluzione ridotta, coords full-res)
    kps: list[np.ndarray] = []
    descs: list[Optional[np.ndarray]] = []
    for i, cam in enumerate(cams):
        img = cv2.imread(str(cam.path), cv2.IMREAD_GRAYSCALE)
        if img is None:
            kps.append(np.empty((0, 2), np.float32))
            descs.append(None)
            continue
        if scale != 1.0:
            img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        kp, de = detector.detectAndCompute(img, None)
        kps.append(np.array([k.pt for k in kp], np.float32).reshape(-1, 2) / scale)
        # SIFT: quantizziamo a uint8 per memoria (i valori sono già ~0..255)
        if de is None:
            descs.append(None)
        else:
            descs.append(de if binary_desc else de.astype(np.uint8))
        if progress and i % 50 == 0:
            print(f"  feature {i}/{len(cams)}  t={time.time()-t0:.0f}s")

    # 2) match per coppia + filtro epipolare dalle pose → union-find
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING if binary_desc else cv2.NORM_L2)
    uf = _UnionFind()
    for npair, (a, b) in enumerate(pairs):
        da, db = descs[a], descs[b]
        if da is None or db is None:
            continue
        if binary_desc:
            knn = matcher.knnMatch(da, db, k=2)
        else:
            knn = matcher.knnMatch(da.astype(np.float32), db.astype(np.float32), k=2)
        good = [m for pair in knn if len(pair) == 2
                for m, s in [pair] if m.distance < RATIO_TEST * s.distance]
        if not good:
            continue
        p1 = kps[a][[m.queryIdx for m in good]]
        p2 = kps[b][[m.trainIdx for m in good]]
        F = _fundamental_from_poses(cams[a], cams[b])
        keep = _epipolar_dist(F, p1, p2) < EPI_THRESH_PX
        for m, k in zip(good, keep):
            if k:
                uf.union((a, m.queryIdx), (b, m.trainIdx))
        if progress and npair % 200 == 0:
            print(f"  match {npair}/{len(pairs)}  t={time.time()-t0:.0f}s")

    # 3) tracce: scarta quelle con 2 feature nella stessa foto (match ambiguo)
    groups: dict = {}
    for key in list(uf.parent):
        groups.setdefault(uf.find(key), []).append(key)
    tracks = []
    for t in groups.values():
        if 2 <= len(t) <= MAX_TRACK_LEN and len({k[0] for k in t}) == len(t):
            tracks.append(t)

    # 4) DLT multi-vista + filtri qualità
    pts3d, nobs_l, rms_l = [], [], []
    for t in tracks:
        obs = [(i, kps[i][k]) for i, k in t]
        A = []
        for ci, uv in obs:
            P = cams[ci].P
            A.append(uv[0] * P[2] - P[0])
            A.append(uv[1] * P[2] - P[1])
        _, _, Vt = np.linalg.svd(np.asarray(A))
        X = Vt[-1]
        if abs(X[3]) < 1e-12:
            continue
        X = X[:3] / X[3]
        if not (Y_MIN_M < X[1] < Y_MAX_M):
            continue
        errs, rays, ok = [], [], True
        for ci, uv in obs:
            c = cams[ci]
            xc = c.R_cv @ X + c.t_cv
            if xc[2] <= 0.1:        # dietro (o troppo vicino a) una camera
                ok = False
                break
            pr = c.K @ xc
            errs.append(np.linalg.norm(pr[:2] / pr[2] - uv))
            r = X - c.C
            rays.append(r / np.linalg.norm(r))
        if not ok or max(errs) > MAX_REPROJ_PX:
            continue
        rays = np.asarray(rays)
        cos_min = float((rays @ rays.T).min())
        if np.degrees(np.arccos(np.clip(cos_min, -1.0, 1.0))) < MIN_PARALLAX_DEG:
            continue
        pts3d.append(X)
        nobs_l.append(len(obs))
        rms_l.append(float(np.sqrt(np.mean(np.square(errs)))))

    return TriangulatedCloud(
        points=np.asarray(pts3d, dtype=np.float64).reshape(-1, 3),
        n_obs=np.asarray(nobs_l, dtype=np.int32),
        rms_px=np.asarray(rms_l, dtype=np.float64),
        camera_centers=np.array([c.C for c in cams]),
        feature_kind=kind,
        n_pairs=len(pairs),
        elapsed_s=time.time() - t0,
    )


# ──────────────────────────────────────────────────────────────────────────
# RANSAC multi-piano
# ──────────────────────────────────────────────────────────────────────────

def _ransac_vertical_plane(
    P: np.ndarray,
    up: np.ndarray,
    rng: np.random.Generator,
    dist_thresh: float,
) -> Optional[tuple[np.ndarray, np.ndarray, np.ndarray]]:
    """Un piano quasi verticale via RANSAC + 2 raffinamenti SVD sugli inlier.

    Ritorna (c, n, inlier_mask) o None se nessun campione valido."""
    n_pts = len(P)
    best_count, best_inl = -1, None
    for _ in range(RANSAC_ITERS):
        idx = rng.choice(n_pts, 3, replace=False)
        a, b, c = P[idx]
        n = np.cross(b - a, c - a)
        nn = np.linalg.norm(n)
        if nn < 1e-9:
            continue
        n = n / nn
        if abs(float(n @ up)) > MAX_NORMAL_UP_DOT:
            continue
        inl = np.abs((P - a) @ n) < dist_thresh
        s = int(inl.sum())
        if s > best_count:
            best_count, best_inl = s, inl
    if best_inl is None:
        return None
    inl = best_inl
    for _ in range(2):
        Q = P[inl]
        c0 = Q.mean(axis=0)
        _, _, Vt = np.linalg.svd(Q - c0, full_matrices=False)
        n = Vt[-1] / np.linalg.norm(Vt[-1])
        inl = np.abs((P - c0) @ n) < dist_thresh
    Q = P[inl]
    c0 = Q.mean(axis=0)
    _, _, Vt = np.linalg.svd(Q - c0, full_matrices=False)
    n = Vt[-1] / np.linalg.norm(Vt[-1])
    return c0, n, inl


def _signed_plane_gap(front: FacadePlane, other: FacadePlane) -> float:
    """Distanza firmata del centro di `other` lungo la normale di `front`
    (n punta verso le camere ⇒ negativa = `other` è DIETRO `front`)."""
    return float((other.c - front.c) @ front.n)


def _dedup_planes(planes: list[FacadePlane]) -> list[FacadePlane]:
    """Fonde piani quasi identici (normali < 3°, gap < 0.3 m): tiene il più
    popolato. Capita quando il RANSAC sequenziale ri-trova lo stesso muro
    sui punti residui."""
    cos_t = np.cos(np.radians(DEDUP_ANGLE_DEG))
    kept: list[FacadePlane] = []
    for p in sorted(planes, key=lambda q: -q.n_inliers):
        dup = any(
            abs(float(p.n @ q.n)) > cos_t and abs(_signed_plane_gap(q, p)) < DEDUP_DIST_M
            for q in kept
        )
        if not dup:
            kept.append(p)
    return kept


def _camera_consensus_normal(cams: list[CameraView]) -> Optional[np.ndarray]:
    """Normale facciata robusta dal consenso delle direzioni di vista.

    Questo riprende il metodo usato negli script locali: l'operatore cammina
    davanti al muro e inquadra la facciata, quindi la media degli assi ottici
    orizzontali è più stabile della normale fittata su una nuvola rada.
    """
    opticals: list[np.ndarray] = []
    for cam in cams:
        opt = np.asarray(cam.fwd, dtype=np.float64).copy()
        opt[1] = 0.0
        nn = np.linalg.norm(opt)
        if nn > 1e-6:
            opticals.append(opt / nn)
    if not opticals:
        return None
    mean_opt = np.mean(opticals, axis=0)
    nn = np.linalg.norm(mean_opt)
    if nn < 1e-6:
        return None
    normal = -mean_opt / nn
    normal[1] = 0.0
    normal /= np.linalg.norm(normal)
    return normal


def _dominant_facade_plane_from_camera_consensus(
    points: np.ndarray,
    cams: list[CameraView],
    *,
    dist_thresh: float = DOMINANT_FACADE_DIST_THRESH_M,
    min_inliers: int = MIN_PLANE_INLIERS,
    seed: int = 11,
) -> Optional[FacadePlane]:
    """Candidato facciata "vecchio RANSAC".

    RANSAC viene usato solo per selezionare un blocco ampio di punti vicini al
    muro. L'orientamento del piano resta quello del consenso camere, con bounds
    robusti sugli inlier. E' meno preciso del multi-piano stretto, ma molto più
    tollerante quando la triangolazione vede solo pezzi di muro tra finestre e
    balconi.
    """
    P = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    if len(P) < min_inliers:
        return None
    normal = _camera_consensus_normal(cams)
    if normal is None:
        return None

    rng = np.random.default_rng(seed)
    best_inl: Optional[np.ndarray] = None
    for _ in range(RANSAC_ITERS):
        idx = rng.choice(len(P), 3, replace=False)
        a, b, c = P[idx]
        n = np.cross(b - a, c - a)
        nn = np.linalg.norm(n)
        if nn < 1e-9:
            continue
        n = n / nn
        if abs(float(n @ np.array([0.0, 1.0, 0.0]))) > MAX_NORMAL_UP_DOT:
            continue
        inl = np.abs((P - a) @ n) < dist_thresh
        if best_inl is None or int(inl.sum()) > int(best_inl.sum()):
            best_inl = inl
    if best_inl is None or int(best_inl.sum()) < min_inliers:
        return None

    Q = P[best_inl]
    c0 = Q.mean(axis=0)
    cam_mean = np.asarray([c.C for c in cams], dtype=np.float64).mean(axis=0)
    if float((cam_mean - c0) @ normal) < 0:
        normal = -normal

    up = np.array([0.0, 1.0, 0.0], dtype=np.float64)
    right = np.cross(up, normal)
    right /= np.linalg.norm(right)
    d = (Q - c0) @ normal
    u = (Q - c0) @ right
    v = (Q - c0) @ up
    return FacadePlane(
        c=c0, n=normal, up=up, right=right,
        bounds=(float(np.percentile(u, 1) - DOMINANT_FACADE_PAD_M),
                float(np.percentile(u, 99) + DOMINANT_FACADE_PAD_M),
                float(np.percentile(v, 1) - DOMINANT_FACADE_PAD_M),
                float(np.percentile(v, 99) + DOMINANT_FACADE_PAD_M)),
        n_inliers=int(best_inl.sum()),
        rms_m=float(np.sqrt(np.mean(d ** 2))),
        inlier_mask=best_inl,
        sample_pts=Q[:: max(1, len(Q) // 2000)].copy(),
    )


def detect_planes(
    points: np.ndarray,
    gravity_up: Sequence[float] = (0.0, 1.0, 0.0),
    *,
    camera_centers: Optional[np.ndarray] = None,
    dist_thresh: float = PLANE_DIST_THRESH_M,
    min_inliers: int = MIN_PLANE_INLIERS,
    max_planes: int = MAX_PLANES,
    seed: int = 7,
) -> list[FacadePlane]:
    """RANSAC sequenziale di piani quasi verticali (|n·up| < 0.1) sulla nuvola.

    `camera_centers` serve per orientare le normali verso le camere e per il
    filtro muro-fantasma; senza, le normali restano col verso del fit SVD e il
    filtro fantasma è disattivato.

    Ritorna i piani ordinati per n_inliers decrescente, già deduplicati e
    senza muri-fantasma."""
    P = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    up = np.asarray(gravity_up, dtype=np.float64)
    up = up / np.linalg.norm(up)
    rng = np.random.default_rng(seed)
    cam_mean = None
    if camera_centers is not None and len(camera_centers):
        cam_mean = np.asarray(camera_centers, dtype=np.float64).mean(axis=0)

    planes: list[FacadePlane] = []
    remaining = P.copy()
    for _ in range(max_planes):
        if len(remaining) < min_inliers * 2:
            break
        res = _ransac_vertical_plane(remaining, up, rng, dist_thresh)
        if res is None:
            break
        c0, n, inl = res
        if int(inl.sum()) < min_inliers:
            break
        # normale verso le camere
        if cam_mean is not None and float((cam_mean - c0) @ n) < 0:
            n = -n
        # basis sul piano: up = gravità proiettata, right = up × n
        up_p = up - n * float(n @ up)
        up_p = up_p / np.linalg.norm(up_p)
        right = np.cross(up_p, n)
        right = right / np.linalg.norm(right)
        Q = remaining[inl]
        d = (Q - c0) @ n
        u = (Q - c0) @ right
        v = (Q - c0) @ up_p
        planes.append(FacadePlane(
            c=c0, n=n, up=up_p, right=right,
            bounds=(float(np.percentile(u, 1)), float(np.percentile(u, 99)),
                    float(np.percentile(v, 1)), float(np.percentile(v, 99))),
            n_inliers=int(inl.sum()),
            rms_m=float(np.sqrt(np.mean(d ** 2))),
            inlier_mask=inl,
            sample_pts=Q[:: max(1, len(Q) // 2000)].copy(),
        ))
        remaining = remaining[~inl]

    planes = _dedup_planes(planes)
    # NB: niente filtro geometrico dei "fantasmi" qui: i piani da match
    # finestra-sbagliata si riconoscono solo fotometricamente
    # (verify_planes_photometric); i filtri geometrici scartavano il muro vero.
    planes.sort(key=lambda p: -p.n_inliers)
    return planes


# ──────────────────────────────────────────────────────────────────────────
# Verifica fotometrica dei piani candidati
# ──────────────────────────────────────────────────────────────────────────
# I match finestra-sbagliata (pattern ripetitivi) generano piani paralleli
# spostati di metri, con track lunghe quanto quelle vere: nessun filtro
# geometrico li distingue. La fisica sì: sul piano VERO le foto proiettate
# concordano (e' il muro); sul piano sbagliato ogni camera proietta una
# finestra diversa -> contenuti scorrelati. Score = NCC mutua media.

PHOTO_SCORE_VIEWS = 5        # camere usate per piano
PHOTO_SCORE_GRID = 220       # lato max della griglia di campionamento
PHOTO_SCORE_MIN = 0.20       # sotto: piano scartato
PHOTO_SCORE_REL = 0.45       # ...o sotto questa frazione del migliore


def _plane_photoconsistency(plane: FacadePlane, cams: list[CameraView],
                            img_cache: dict) -> float:
    a, b, lo, hi = plane.bounds
    # margine interno per evitare i bordi dell'impronta
    du = (b - a) * 0.08
    dv = (hi - lo) * 0.08
    a, b, lo, hi = a + du, b - du, lo + dv, hi - dv
    if b - a < 1.0 or hi - lo < 1.0:
        return 0.0
    gw = PHOTO_SCORE_GRID
    gh = max(8, int(gw * (hi - lo) / (b - a)))
    uu, vv = np.meshgrid(np.linspace(a, b, gw), np.linspace(hi, lo, gh))
    Q = (plane.c[None, None, :] + uu[..., None] * plane.right
         + vv[..., None] * plane.up).reshape(-1, 3)
    # camere candidate: frontali e vicine al centro del piano
    scored = []
    for c in cams:
        d = c.C - plane.c
        dist = float(np.linalg.norm(d))
        frontal = float((d / max(dist, 1e-6)) @ plane.n)
        if frontal < 0.25:
            continue
        scored.append((frontal / (1.0 + 0.05 * dist), c))
    scored.sort(key=lambda s: -s[0])
    views = []
    for _, c in scored[:PHOTO_SCORE_VIEWS * 3]:
        if len(views) >= PHOTO_SCORE_VIEWS:
            break
        if c.path not in img_cache:
            im = cv2.imread(str(c.path), cv2.IMREAD_GRAYSCALE)
            if im is None:
                continue
            img_cache[c.path] = cv2.resize(im, (0, 0), fx=0.5, fy=0.5)
        im = img_cache[c.path]
        xc = (c.R_cv @ Q.T).T + c.t_cv
        z = xc[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            px = (c.K[0, 0] * xc[:, 0] / z + c.K[0, 2]) * 0.5
            py = (c.K[1, 1] * xc[:, 1] / z + c.K[1, 2]) * 0.5
        valid = (z > 0.1) & (px >= 0) & (py >= 0) \
            & (px < im.shape[1] - 1) & (py < im.shape[0] - 1)
        if valid.mean() < 0.3:
            continue
        g = cv2.remap(im, px.reshape(gh, gw).astype(np.float32),
                      py.reshape(gh, gw).astype(np.float32),
                      cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT,
                      borderValue=0).astype(np.float32)
        views.append((g, valid.reshape(gh, gw)))
    if len(views) < 3:
        return 0.0
    # NCC per TESSERE locali su contenuto passa-alto, mediana su tessere+coppie:
    # la facciata periodica puo' correlare globalmente anche su un piano
    # sbagliato (allineamento al passo di una finestra); localmente no.
    TILE = 28
    def _highpass(g):
        return g - cv2.boxFilter(g, -1, (15, 15))
    hp = [( _highpass(g), m) for g, m in views]
    nccs = []
    gh_, gw_ = hp[0][0].shape
    for i in range(len(hp)):
        for j in range(i + 1, len(hp)):
            gi, mi = hp[i]
            gj, mj = hp[j]
            m = mi & mj
            for ty in range(0, gh_ - TILE + 1, TILE):
                for tx in range(0, gw_ - TILE + 1, TILE):
                    mt = m[ty:ty + TILE, tx:tx + TILE]
                    if mt.mean() < 0.8:
                        continue
                    x = gi[ty:ty + TILE, tx:tx + TILE][mt]
                    y = gj[ty:ty + TILE, tx:tx + TILE][mt]
                    sx, sy = x.std(), y.std()
                    if sx < 2.0 or sy < 2.0:    # tessera senza contenuto
                        continue
                    x = x - x.mean(); y = y - y.mean()
                    nccs.append(float((x * y).mean() / (sx * sy)))
    if len(nccs) < 20:
        return 0.0
    return float(np.median(nccs))


def verify_planes_photometric(planes: list[FacadePlane],
                              cams: list[CameraView]) -> list[FacadePlane]:
    """Assegna a ogni piano lo score fotometrico e scarta i piani-fantasma
    (score basso in assoluto o rispetto al migliore). Ordina per score."""
    img_cache: dict = {}
    for p in planes:
        p.photo_score = _plane_photoconsistency(p, cams, img_cache)
    best = max((p.photo_score for p in planes), default=0.0)
    kept = [p for p in planes
            if p.photo_score >= max(PHOTO_SCORE_MIN, PHOTO_SCORE_REL * best)]
    kept.sort(key=lambda p: -p.photo_score)
    return kept


# ──────────────────────────────────────────────────────────────────────────
# Entry point di alto livello (usato dall'endpoint /planes)
# ──────────────────────────────────────────────────────────────────────────

def detect_facade_planes(
    photos_dir: Union[str, Path],
    photos_json: Union[str, Path, Sequence[dict]],
    *,
    step: int = 1,
    scale: float = DEFAULT_SCALE,
    nfeatures: int = DEFAULT_NFEATURES,
    max_planes: int = MAX_PLANES,
    min_inliers: int = MIN_PLANE_INLIERS,
    progress: bool = False,
    return_cloud: bool = False,
) -> Union[dict, tuple[dict, TriangulatedCloud]]:
    """Triangola la sessione e rileva i piani di facciata. Tutto in uno.

    Ritorna un dict serializzabile JSON:
      {"planes": [piano, ...],   # ordinati per n_inliers, formato true_plane
       "stats": {n_points, feature_kind, n_pairs, elapsed_s, ...}}

    Con `return_cloud=True` ritorna (dict, TriangulatedCloud) — la nuvola serve
    a valle per le proposte di zone fuori-piano (zone_proposals).
    """
    t0 = time.time()
    cloud = triangulate_session(photos_dir, photos_json,
                                step=step, scale=scale, nfeatures=nfeatures,
                                progress=progress)
    cams = load_cameras(photos_dir, photos_json)
    dominant = _dominant_facade_plane_from_camera_consensus(
        cloud.points, cams, min_inliers=min_inliers
    )
    planes = detect_planes(cloud.points, camera_centers=cloud.camera_centers,
                           max_planes=max_planes, min_inliers=min_inliers)
    if dominant is not None:
        planes = _dedup_planes([dominant, *planes])
        planes.sort(key=lambda p: -p.n_inliers)
    # verifica fotometrica: scarta i piani-fantasma da match ripetitivi
    planes = verify_planes_photometric(planes, cams)
    result = {
        "planes": [p.to_dict() for p in planes],
        "stats": {
            "n_points": int(len(cloud.points)),
            "n_cameras": int(len(cloud.camera_centers)),
            "n_pairs": int(cloud.n_pairs),
            "feature_kind": cloud.feature_kind,
            "median_reproj_rms_px": float(np.median(cloud.rms_px)) if len(cloud.rms_px) else None,
            "elapsed_s": float(round(time.time() - t0, 1)),
        },
    }
    if return_cloud:
        return result, cloud
    return result
