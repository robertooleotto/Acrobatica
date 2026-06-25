"""Test della pre-marcatura automatica (zone fuori-piano da nuvola sintetica)."""
import numpy as np
import pytest

from app.services.zone_proposals import proponi_zone

# Piano facciata "comodo": ARKit world con muro sul piano z=0, normale +z
# (verso le camere), up=+y, right=+x. Bounds 10×6 m.
PIANO = {
    "c": [5.0, 3.0, 0.0],
    "n": [0.0, 0.0, 1.0],
    "up": [0.0, 1.0, 0.0],
    "right": [1.0, 0.0, 0.0],
    "bounds": [-5.0, 5.0, -3.0, 3.0],  # u in [-5,5], v in [-3,3] rispetto a c
}


def _muro(n=4000, seed=1):
    """Punti sul piano (rumore 2 cm) sparsi su tutta la facciata."""
    rng = np.random.default_rng(seed)
    u = rng.uniform(-5, 5, n)
    v = rng.uniform(-3, 3, n)
    z = rng.normal(0, 0.02, n)
    return np.column_stack([5.0 + u, 3.0 + v, z])


def _balcone(n=800, seed=2):
    """Blocco sporgente 60 cm davanti al muro, 2×1 m in alto a destra:
    u in [2,4], v in [1,2]."""
    rng = np.random.default_rng(seed)
    u = rng.uniform(2, 4, n)
    v = rng.uniform(1, 2, n)
    z = rng.uniform(0.4, 0.6, n)
    return np.column_stack([5.0 + u, 3.0 + v, z])


def test_nessuna_proposta_su_muro_piatto():
    doc = proponi_zone(_muro(), PIANO, ppm=100)
    assert doc.zone == []
    assert doc.larghezza_px == 1000 and doc.altezza_px == 600


def test_balcone_trovato_e_in_posizione():
    punti = np.vstack([_muro(), _balcone()])
    doc = proponi_zone(punti, PIANO, ppm=100)
    assert len(doc.zone) == 1
    z = doc.zone[0]
    assert z.tipo == "esclusa"
    assert "auto" in z.nome
    # Area attesa ~2 m² (griglia 20 cm → tolleranza larga)
    assert z.area_m2 == pytest.approx(2.0, abs=0.8)
    # Posizione attesa in px ortofoto (ppm=100, origine alto-sx):
    # u∈[2,4] → x∈[700,900]; v∈[1,2] → y = (3−v)·100 ∈ [100,200]
    xs = [p[0] for p in z.punti_px]
    ys = [p[1] for p in z.punti_px]
    assert min(xs) == pytest.approx(700, abs=30)
    assert max(xs) == pytest.approx(900, abs=30)
    assert min(ys) == pytest.approx(100, abs=30)
    assert max(ys) == pytest.approx(200, abs=30)


def test_rientranza_ignorata_di_default():
    """Punti DIETRO il piano (δ negativa, es. finestra) non vanno proposti."""
    rng = np.random.default_rng(3)
    rientranza = np.column_stack([
        5.0 + rng.uniform(-1, 1, 500),
        3.0 + rng.uniform(-1, 1, 500),
        rng.uniform(-0.6, -0.4, 500),
    ])
    punti = np.vstack([_muro(), rientranza])
    assert proponi_zone(punti, PIANO, ppm=100).zone == []
    # ... ma con solo_sporgenze=False sì
    doc = proponi_zone(punti, PIANO, ppm=100, solo_sporgenze=False)
    assert len(doc.zone) == 1


def test_zone_piccole_filtrate():
    """Un ciuffetto di punti sporgenti sotto l'area minima non genera zone."""
    rng = np.random.default_rng(4)
    ciuffo = np.column_stack([
        5.0 + rng.uniform(0, 0.3, 60),
        3.0 + rng.uniform(0, 0.3, 60),
        rng.uniform(0.3, 0.5, 60),
    ])
    punti = np.vstack([_muro(), ciuffo])
    assert proponi_zone(punti, PIANO, ppm=100).zone == []


def test_ppm_non_valido():
    with pytest.raises(ValueError):
        proponi_zone(_muro(), PIANO, ppm=0)
