"""Estrazione SEMI-AUTOMATICA della geometria 3D di una facciata.

Filosofia (è il cuore del modulo): la nuvola di punti fotografica è RADA, quindi
NON proviamo a estrarre automaticamente i volumi (torrette, logge, nicchie) —
darebbe blob inaffidabili. Invece l'UTENTE disegna i poligoni delle regioni
sull'ortofoto, e il BACKEND, per ogni poligono, campiona la nuvola e restituisce
la PROFONDITÀ robusta (mediana + MAD, scartando outlier). Poligono + profondità
→ prisma estruso con le sue spallette (pareti laterali).

Niente open3d (la nuvola è un .npz di soli punti), niente mesh/Object Capture,
niente Umeyama: la geometria qui è 100% fotografica.

Convenzione ortofoto / piano (v22, vedi `zone_proposals` e `facade_planes`):
  rel = X − c
  u = rel·right,  v = rel·up,  w = rel·n   (w>0 = SPORGE verso le camere)
  pixel ortofoto (origine in alto a sinistra):
    x_px = (u − u_min)·ppm
    y_px = (v_max − v)·ppm
  ppm tipico 110. `plane` è il dict prodotto da `FacadePlane.to_dict()`
  (chiavi c, n, up, right, bounds=[u_min,u_max,v_min,v_max]).
"""
from __future__ import annotations

from typing import Sequence

import numpy as np

# ── Parametri di default ────────────────────────────────────────────────────
MAD_OUTLIER_K = 2.5          # scarta punti oltre k·MAD dalla mediana di w
MIN_PUNTI_PROFONDITA = 8     # sotto: nessuna stima, serve profondità a mano
ALTA_MIN_PUNTI = 40          # confidence 'alta' richiede ≥ questo
ALTA_MAX_MAD_CM = 8.0        # ...e MAD < questo
FILO_SOGLIA_M = 0.08         # |depth| sotto questa = 'filo' (a filo del piano)
SEZIONE_BIN_M = 0.25         # larghezza bin di u nella sezione orizzontale
SEZIONE_BAND_M = 0.5         # spessore di default della fascia di quota
# 1.4826 ≈ fattore che rende la MAD uno stimatore consistente di σ per gaussiane
_MAD_TO_SIGMA = 1.4826


# ──────────────────────────────────────────────────────────────────────────
# Helper geometrici
# ──────────────────────────────────────────────────────────────────────────

def _plane_basis(plane: dict):
    """Estrae (c, n, up, right, bounds) dal dict piano come array float64."""
    c = np.asarray(plane["c"], dtype=np.float64)
    n = np.asarray(plane["n"], dtype=np.float64)
    up = np.asarray(plane["up"], dtype=np.float64)
    right = np.asarray(plane["right"], dtype=np.float64)
    bounds = tuple(float(b) for b in plane["bounds"])  # (u_min,u_max,v_min,v_max)
    return c, n, up, right, bounds


def _px_to_uv(poly_px: Sequence[Sequence[float]], bounds, ppm: float) -> np.ndarray:
    """Converte i vertici poligono da pixel ortofoto a coord piano (u,v) in metri.

    Inverte la convenzione v22:  x_px=(u−u_min)·ppm,  y_px=(v_max−v)·ppm."""
    u_min, _u_max, _v_min, v_max = bounds
    poly = np.asarray(poly_px, dtype=np.float64).reshape(-1, 2)
    u = u_min + poly[:, 0] / ppm
    v = v_max - poly[:, 1] / ppm
    return np.column_stack([u, v])


def _point_in_polygon(pts_uv: np.ndarray, poly_uv: np.ndarray) -> np.ndarray:
    """Point-in-polygon vettoriale (ray casting) su un insieme di punti.

    `pts_uv` (N,2), `poly_uv` (M,2) vertici ordinati del poligono (aperto o
    chiuso indifferentemente). Ritorna mask booleana (N,) True = dentro.
    I punti esattamente sul bordo possono cadere da entrambe le parti: per il
    campionamento di una nuvola rada è irrilevante."""
    pts = np.asarray(pts_uv, dtype=np.float64).reshape(-1, 2)
    poly = np.asarray(poly_uv, dtype=np.float64).reshape(-1, 2)
    n = len(poly)
    if n < 3 or len(pts) == 0:
        return np.zeros(len(pts), dtype=bool)
    x, y = pts[:, 0], pts[:, 1]
    inside = np.zeros(len(pts), dtype=bool)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        # il lato (j→i) attraversa la quota y del punto?
        cond = (yi > y) != (yj > y)
        # ascissa dell'intersezione del lato con la retta orizzontale per il punto
        denom = (yj - yi) if abs(yj - yi) > 1e-15 else 1e-15
        x_cross = xi + (y - yi) * (xj - xi) / denom
        inside ^= cond & (x < x_cross)
        j = i
    return inside


def _robust_depth(w: np.ndarray):
    """Mediana + MAD robusta di w scartando outlier oltre k·MAD.

    Ritorna (depth_m, mad_m, n_inlier, inlier_mask). I riflessi nei vetri
    triangolano a w molto diverso (tipicamente metri davanti/dietro) → cadono
    fuori da k·MAD e vengono filtrati."""
    w = np.asarray(w, dtype=np.float64).ravel()
    med = float(np.median(w))
    mad = float(np.median(np.abs(w - med)))
    sigma = mad * _MAD_TO_SIGMA
    if sigma < 1e-9:
        # nuvola degenere (tutti uguali): nessun outlier da scartare
        inl = np.ones(len(w), dtype=bool)
    else:
        inl = np.abs(w - med) <= MAD_OUTLIER_K * sigma
    w_in = w[inl]
    if len(w_in) == 0:
        return med, mad, 0, inl
    med2 = float(np.median(w_in))
    mad2 = float(np.median(np.abs(w_in - med2)))
    return med2, mad2, int(inl.sum()), inl


def _classifica_tipo(depth_m: float) -> str:
    """'estruso' se sporge oltre soglia, 'rientrato' se incassa, 'filo' altrimenti."""
    if depth_m > FILO_SOGLIA_M:
        return "estruso"
    if depth_m < -FILO_SOGLIA_M:
        return "rientrato"
    return "filo"


# ──────────────────────────────────────────────────────────────────────────
# 1) Profondità robusta di un poligono disegnato dall'utente
# ──────────────────────────────────────────────────────────────────────────

def extrude_polygon(
    poly_px: Sequence[Sequence[float]],
    cloud_points: np.ndarray,
    plane: dict,
    ppm: float,
) -> dict:
    """Profondità robusta della regione racchiusa da `poly_px` (px ortofoto).

    (a) converte i vertici del poligono in coord piano (u,v);
    (b) seleziona i punti della nuvola che proiettano DENTRO il poligono
        (point-in-polygon su (u,v));
    (c) calcola la profondità w robusta: mediana + MAD, scartando outlier oltre
        2.5·MAD (i riflessi nei vetri stanno a w molto diverso → filtrati);
    (d) classifica il tipo e assegna una confidence.

    Se i punti dentro il poligono sono troppo pochi (< 8) ritorna
    confidence='nessuna', depth=0 (filo) e needs_user_depth=True: l'utente
    metterà la profondità a mano.

    Ritorna un dict serializzabile JSON:
      {depth_m, depth_mad_cm, n_points, confidence, tipo, needs_user_depth}
    """
    if ppm <= 0:
        raise ValueError(f"ppm non valido: {ppm}")
    c, n, up, right, bounds = _plane_basis(plane)
    P = np.asarray(cloud_points, dtype=np.float64).reshape(-1, 3)

    poly_uv = _px_to_uv(poly_px, bounds, ppm)
    if len(poly_uv) < 3:
        raise ValueError("poly_px deve avere almeno 3 vertici")

    base = {
        "depth_m": 0.0,
        "depth_mad_cm": 0.0,
        "n_points": 0,
        "confidence": "nessuna",
        "tipo": "filo",
        "needs_user_depth": True,
    }
    if len(P) == 0:
        return base

    rel = P - c
    u = rel @ right
    v = rel @ up
    w = rel @ n
    dentro = _point_in_polygon(np.column_stack([u, v]), poly_uv)
    n_dentro = int(dentro.sum())
    if n_dentro < MIN_PUNTI_PROFONDITA:
        base["n_points"] = n_dentro
        return base

    depth_m, mad_m, n_inlier, _ = _robust_depth(w[dentro])
    mad_cm = mad_m * 100.0
    if n_inlier >= ALTA_MIN_PUNTI and mad_cm < ALTA_MAX_MAD_CM:
        confidence = "alta"
    elif n_inlier >= MIN_PUNTI_PROFONDITA:
        confidence = "media"
    else:
        confidence = "bassa"

    return {
        "depth_m": float(depth_m),
        "depth_mad_cm": float(mad_cm),
        "n_points": int(n_inlier),
        "confidence": confidence,
        "tipo": _classifica_tipo(depth_m),
        "needs_user_depth": False,
    }


# ──────────────────────────────────────────────────────────────────────────
# 2) Sezione orizzontale: profilo di supporto per l'editor
# ──────────────────────────────────────────────────────────────────────────

def horizontal_section(
    cloud_points: np.ndarray,
    plane: dict,
    v_quota: float,
    band: float = SEZIONE_BAND_M,
    bin_m: float = SEZIONE_BIN_M,
) -> list[dict]:
    """Profilo orizzontale (u, w_mediano) per una fascia di quota [v_quota±band/2].

    È lo strumento di supporto che l'editor mostra all'utente per disegnare /
    confermare le profondità: dove il muro avanza (torretta) w cresce, dove
    rientra (loggia) cala. Per ogni bin di u (default 25 cm) calcola w mediano
    con filtro outlier (k·MAD) e conta i punti.

    Ritorna lista di {u_m, w_m, n} ordinata per u crescente (solo bin non vuoti).
    """
    if band <= 0 or bin_m <= 0:
        raise ValueError("band e bin_m devono essere > 0")
    c, n, up, right, bounds = _plane_basis(plane)
    u_min, u_max, _v_min, _v_max = bounds
    P = np.asarray(cloud_points, dtype=np.float64).reshape(-1, 3)
    if len(P) == 0:
        return []

    rel = P - c
    u = rel @ right
    v = rel @ up
    w = rel @ n
    half = band / 2.0
    fascia = (v >= v_quota - half) & (v <= v_quota + half)
    if not np.any(fascia):
        return []
    u_f, w_f = u[fascia], w[fascia]

    # bin di u ancorati a u_min del piano (coerente con la griglia ortofoto)
    nb = max(1, int(np.ceil((u_max - u_min) / bin_m)))
    idx = np.clip(((u_f - u_min) / bin_m).astype(int), 0, nb - 1)
    profilo: list[dict] = []
    for b in range(nb):
        sel = idx == b
        m = int(sel.sum())
        if m == 0:
            continue
        w_bin = w_f[sel]
        if m >= MIN_PUNTI_PROFONDITA:
            w_med, _mad, n_in, _ = _robust_depth(w_bin)
        else:
            w_med, n_in = float(np.median(w_bin)), m
        u_centro = u_min + (b + 0.5) * bin_m
        profilo.append({"u_m": float(u_centro), "w_m": float(w_med), "n": int(n_in)})
    return profilo


# ──────────────────────────────────────────────────────────────────────────
# 3) Modello a scatole: piano base + prismi estrusi con spallette
# ──────────────────────────────────────────────────────────────────────────

def _uv_world(c, right, up, n, u: float, v: float, w: float) -> np.ndarray:
    """Punto 3D world dato (u,v,w) nel frame del piano."""
    return c + u * right + v * up + w * n


def build_facade_model(plane: dict, prisms: Sequence[dict], ppm: float) -> dict:
    """Costruisce il modello a scatole della facciata.

    Per ogni prisma {poly_px, depth_m, tipo, nome}:
      - la FACCIA FRONTALE: il poligono portato a quota w=depth_m;
      - le SPALLETTE: per ogni lato del contorno un quad verticale che va dal
        piano base (w=0) alla profondità (w=depth_m). Sono le pareti laterali
        della torretta / della nicchia.
    Il piano base è un singolo quad sui bounds del piano.

    Ritorna {"model_json": {...}, "obj_text": "..."}. Il model_json è EDITABILE
    (l'utente può poi spostare profondità/poligoni e ricostruire l'OBJ).
    """
    if ppm <= 0:
        raise ValueError(f"ppm non valido: {ppm}")
    c, n, up, right, bounds = _plane_basis(plane)
    u_min, u_max, v_min, v_max = bounds

    verts: list[list[float]] = []   # vertici 3D world (per l'OBJ)
    faces: list[list[int]] = []     # facce come liste di indici 1-based (OBJ)
    model_prisms: list[dict] = []

    def add_vert(p: np.ndarray) -> int:
        verts.append([float(p[0]), float(p[1]), float(p[2])])
        return len(verts)  # OBJ è 1-based

    # ── Piano base (quad sui bounds del piano, w=0) ──
    base_uv = [(u_min, v_min), (u_max, v_min), (u_max, v_max), (u_min, v_max)]
    base_idx = [add_vert(_uv_world(c, right, up, n, u, v, 0.0)) for u, v in base_uv]
    faces.append(base_idx)

    # ── Un prisma per regione disegnata ──
    for pr in prisms:
        poly_px = pr["poly_px"]
        depth = float(pr.get("depth_m", 0.0))
        nome = pr.get("nome", "regione")
        tipo = pr.get("tipo") or _classifica_tipo(depth)

        poly_uv = _px_to_uv(poly_px, bounds, ppm)
        if len(poly_uv) < 3:
            continue

        # faccia frontale: poligono a quota w=depth
        front_idx = [add_vert(_uv_world(c, right, up, n, u, v, depth))
                     for u, v in poly_uv]
        # base del prisma (stesso contorno a w=0): serve per le spallette
        back_idx = [add_vert(_uv_world(c, right, up, n, u, v, 0.0))
                    for u, v in poly_uv]

        faces.append(list(front_idx))  # faccia frontale (estrusa)

        # spallette: un quad per lato (back_i, back_j, front_j, front_i)
        m = len(poly_uv)
        spallette: list[list[int]] = []
        for i in range(m):
            jj = (i + 1) % m
            quad = [back_idx[i], back_idx[jj], front_idx[jj], front_idx[i]]
            faces.append(quad)
            spallette.append(quad)

        model_prisms.append({
            "nome": nome,
            "tipo": tipo,
            "depth_m": depth,
            "poly_px": [[float(x), float(y)]
                        for x, y in np.asarray(poly_px, float).reshape(-1, 2)],
            "front_face": list(front_idx),
            "spallette": spallette,
        })

    model_json = {
        "plane": {
            "c": [float(x) for x in c],
            "n": [float(x) for x in n],
            "up": [float(x) for x in up],
            "right": [float(x) for x in right],
            "bounds": [float(b) for b in bounds],
            "ppm": float(ppm),
        },
        "base_face": base_idx,
        "prisms": model_prisms,
        "vertices": verts,
        "faces": faces,
        "n_vertices": len(verts),
        "n_faces": len(faces),
    }

    # ── OBJ testuale (v / f), parsabile da qualsiasi viewer ──
    lines = ["# Modello facciata Acrobatica (geometria fotografica)",
             f"# {len(verts)} vertici, {len(faces)} facce"]
    for vx in verts:
        lines.append(f"v {vx[0]:.6f} {vx[1]:.6f} {vx[2]:.6f}")
    for f in faces:
        lines.append("f " + " ".join(str(i) for i in f))
    obj_text = "\n".join(lines) + "\n"

    return {"model_json": model_json, "obj_text": obj_text}
