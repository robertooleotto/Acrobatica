"""Test dell'estrazione semi-automatica della geometria 3D (facade_geometry).

Nessuna dipendenza da ground-truth esterno: coerenza interna + dati SINTETICI.
Si genera un piano "comodo" (muro su z=0, normale +z verso le camere, up=+y,
right=+x) e blocchi a profondità note. Uno smoke test gira sulla fixture reale
6cdcb8ff SE è presente `out/cloud.npz` (altrimenti viene saltato).
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from app.services.facade_geometry import (
    build_facade_model,
    extrude_polygon,
    horizontal_section,
)

# Piano facciata sintetico: muro su z=0, n=+z (verso camere), up=+y, right=+x.
# c=(5,3,0); bounds u∈[-5,5], v∈[-3,3]. ppm=100 → ortofoto 1000×600 px.
PIANO = {
    "c": [5.0, 3.0, 0.0],
    "n": [0.0, 0.0, 1.0],
    "up": [0.0, 1.0, 0.0],
    "right": [1.0, 0.0, 0.0],
    "bounds": [-5.0, 5.0, -3.0, 3.0],
    "ppm": 100.0,
}
PPM = 100.0

BACKEND = Path(__file__).resolve().parents[1]
FIXTURE_CLOUD = BACKEND / "data" / "fixtures" / "6cdcb8ff" / "out" / "cloud.npz"


def _muro(n=4000, seed=1):
    """Punti sul piano (rumore 2 cm) su tutta la facciata."""
    rng = np.random.default_rng(seed)
    u = rng.uniform(-5, 5, n)
    v = rng.uniform(-3, 3, n)
    w = rng.normal(0, 0.02, n)
    return np.column_stack([5.0 + u, 3.0 + v, w])


def _blocco(u_lo, u_hi, v_lo, v_hi, depth, n=1500, sigma=0.02, seed=2):
    """Blocco a profondità w=depth (rumore sigma) nel rettangolo (u,v)."""
    rng = np.random.default_rng(seed)
    u = rng.uniform(u_lo, u_hi, n)
    v = rng.uniform(v_lo, v_hi, n)
    w = rng.normal(depth, sigma, n)
    return np.column_stack([5.0 + u, 3.0 + v, w])


def _rect_px(u_lo, u_hi, v_lo, v_hi):
    """Rettangolo (u,v in metri) → poligono in px ortofoto (convenzione v22)."""
    u_min, _u_max, _v_min, v_max = PIANO["bounds"]

    def px(u, v):
        return [(u - u_min) * PPM, (v_max - v) * PPM]

    # ordine orario in px: TL, TR, BR, BL
    return [px(u_lo, v_hi), px(u_hi, v_hi), px(u_hi, v_lo), px(u_lo, v_lo)]


# ── extrude_polygon ─────────────────────────────────────────────────────────

def test_extrude_blocco_estruso_con_outlier_filtrati():
    """Blocco noto a +0.80 m dentro un rettangolo, con riflessi iniettati a
    w=+2 m: depth≈0.80, tipo estruso, confidence alta, outlier filtrati."""
    poly = _rect_px(1.0, 3.0, 0.0, 2.0)
    blocco = _blocco(1.0, 3.0, 0.0, 2.0, depth=0.80, n=1500, sigma=0.02)
    # riflessi nei vetri: stessi (u,v) del blocco ma w=+2 m
    rng = np.random.default_rng(99)
    rifl = np.column_stack([
        5.0 + rng.uniform(1.0, 3.0, 200),
        3.0 + rng.uniform(0.0, 2.0, 200),
        rng.normal(2.0, 0.05, 200),
    ])
    punti = np.vstack([_muro(), blocco, rifl])

    out = extrude_polygon(poly, punti, PIANO, ppm=PPM)
    assert out["depth_m"] == pytest.approx(0.80, abs=0.05)
    assert out["tipo"] == "estruso"
    assert out["confidence"] == "alta"
    assert not out["needs_user_depth"]
    # gli outlier a 2 m sono stati scartati → MAD piccola (≈ rumore 2 cm)
    assert out["depth_mad_cm"] < 8.0


def test_extrude_point_in_polygon_esclude_esterni():
    """Un poligono piccolo NON deve includere i punti del blocco fuori da esso.
    Blocco a destra (u∈[3,4]); poligono a sinistra (u∈[-2,-1]) → vede solo muro."""
    blocco = _blocco(3.0, 4.0, 0.0, 1.0, depth=0.80, n=1500)
    punti = np.vstack([_muro(), blocco])
    poly = _rect_px(-2.0, -1.0, -1.0, 1.0)
    out = extrude_polygon(poly, punti, PIANO, ppm=PPM)
    # nel poligono c'è solo il muro piatto → depth≈0, filo
    assert out["depth_m"] == pytest.approx(0.0, abs=0.05)
    assert out["tipo"] == "filo"


def test_extrude_rientranza():
    """Blocco a −0.50 m (nicchia incassata) → tipo rientrato."""
    poly = _rect_px(0.0, 1.5, 0.0, 1.5)
    nicchia = _blocco(0.0, 1.5, 0.0, 1.5, depth=-0.50, n=1000)
    punti = np.vstack([_muro(), nicchia])
    out = extrude_polygon(poly, punti, PIANO, ppm=PPM)
    assert out["depth_m"] == pytest.approx(-0.50, abs=0.05)
    assert out["tipo"] == "rientrato"


def test_extrude_pochi_punti_richiede_profondita_manuale():
    """Poligono in zona quasi vuota → needs_user_depth, confidence nessuna."""
    # solo 3 punti dentro un poligono minuscolo lontano dal grosso del muro
    pochi = np.array([
        [5.0 + 4.6, 3.0 + 2.6, 0.5],
        [5.0 + 4.7, 3.0 + 2.7, 0.5],
        [5.0 + 4.65, 3.0 + 2.65, 0.5],
    ])
    poly = _rect_px(4.5, 4.8, 2.5, 2.8)
    out = extrude_polygon(poly, pochi, PIANO, ppm=PPM)
    assert out["needs_user_depth"] is True
    assert out["confidence"] == "nessuna"
    assert out["depth_m"] == 0.0


def test_extrude_ppm_non_valido():
    poly = _rect_px(0, 1, 0, 1)
    with pytest.raises(ValueError):
        extrude_polygon(poly, _muro(), PIANO, ppm=0)


# ── horizontal_section ──────────────────────────────────────────────────────

def test_horizontal_section_profilo_atteso():
    """Una torretta che sporge a +0.6 m su u∈[1,3] deve apparire come w≈0.6 nei
    bin centrali e w≈0 fuori, alla quota della fascia."""
    torretta = _blocco(1.0, 3.0, -1.0, 1.0, depth=0.60, n=3000, sigma=0.02)
    punti = np.vstack([_muro(), torretta])
    profilo = horizontal_section(punti, PIANO, v_quota=0.0, band=0.5)
    assert profilo, "profilo vuoto"
    by_u = {round(b["u_m"], 3): b["w_m"] for b in profilo}
    # bin dentro la torretta (u≈2) ≈ 0.6
    dentro = [w for u, w in by_u.items() if 1.2 < u < 2.8]
    fuori = [w for u, w in by_u.items() if u < 0.5 or u > 3.5]
    assert dentro and max(dentro) == pytest.approx(0.6, abs=0.08)
    assert fuori and max(abs(w) for w in fuori) < 0.08
    # bin ordinati per u crescente
    us = [b["u_m"] for b in profilo]
    assert us == sorted(us)


def test_horizontal_section_fascia_vuota():
    """Quota fuori dai punti → profilo vuoto, niente eccezioni."""
    assert horizontal_section(_muro(), PIANO, v_quota=100.0, band=0.5) == []


# ── build_facade_model ──────────────────────────────────────────────────────

def test_build_model_prisma_ha_quattro_spallette():
    """Un prisma rettangolare (4 lati) → 4 spallette; faccia frontale + base;
    conteggi vertici/facce coerenti; OBJ parsabile."""
    poly = _rect_px(1.0, 3.0, 0.0, 2.0)  # rettangolo: 4 vertici
    prisms = [{"poly_px": poly, "depth_m": 0.8, "tipo": "estruso", "nome": "torretta"}]
    out = build_facade_model(PIANO, prisms, ppm=PPM)
    mj = out["model_json"]

    # vertici: 4 (base piano) + 4 (front) + 4 (back) = 12
    assert mj["n_vertices"] == 12
    # facce: 1 base piano + 1 faccia frontale + 4 spallette = 6
    assert mj["n_faces"] == 6
    assert len(mj["prisms"]) == 1
    assert len(mj["prisms"][0]["spallette"]) == 4

    # OBJ parsabile: conta v e f, e gli indici delle facce sono validi (1-based)
    v_count = f_count = 0
    for line in out["obj_text"].splitlines():
        if line.startswith("v "):
            assert len(line.split()) == 4
            v_count += 1
        elif line.startswith("f "):
            idxs = [int(t) for t in line.split()[1:]]
            assert all(1 <= i <= mj["n_vertices"] for i in idxs)
            f_count += 1
    assert v_count == mj["n_vertices"]
    assert f_count == mj["n_faces"]


def test_build_model_front_face_alla_profondita():
    """La faccia frontale del prisma estruso deve stare a w=depth dal piano."""
    poly = _rect_px(1.0, 3.0, 0.0, 2.0)
    depth = 0.8
    prisms = [{"poly_px": poly, "depth_m": depth, "tipo": "estruso", "nome": "t"}]
    mj = build_facade_model(PIANO, prisms, ppm=PPM)["model_json"]
    verts = np.asarray(mj["vertices"])
    c = np.asarray(PIANO["c"]); n = np.asarray(PIANO["n"])
    front_idx = mj["prisms"][0]["front_face"]
    for i in front_idx:
        w = float((verts[i - 1] - c) @ n)  # OBJ 1-based
        assert w == pytest.approx(depth, abs=1e-6)


def test_build_model_ppm_non_valido():
    poly = _rect_px(0, 1, 0, 1)
    with pytest.raises(ValueError):
        build_facade_model(PIANO, [{"poly_px": poly, "depth_m": 0.3}], ppm=0)


# ── Smoke test su fixture reale (skip se manca la nuvola) ───────────────────

@pytest.mark.skipif(not FIXTURE_CLOUD.exists(),
                    reason="fixture out/cloud.npz non presente")
def test_smoke_extrude_su_nuvola_reale():
    """Su un rettangolo centrale della facciata reale: n_points > 0."""
    import json as _json

    points = np.load(FIXTURE_CLOUD)["points"]
    true_plane = _json.loads(
        (Path(__file__).parent / "data" / "true_plane_6cdcb8ff.json").read_text())
    u_min, u_max, v_min, v_max = true_plane["bounds"]
    ppm = true_plane.get("ppm", 110.0)
    # rettangolo centrale (40% centrale dei bounds) in px
    cu = (u_min + u_max) / 2; cv = (v_min + v_max) / 2
    du = (u_max - u_min) * 0.2; dv = (v_max - v_min) * 0.2

    def px(u, v):
        return [(u - u_min) * ppm, (v_max - v) * ppm]

    poly = [px(cu - du, cv + dv), px(cu + du, cv + dv),
            px(cu + du, cv - dv), px(cu - du, cv - dv)]
    out = extrude_polygon(poly, points, true_plane, ppm=ppm)
    assert out["n_points"] > 0
