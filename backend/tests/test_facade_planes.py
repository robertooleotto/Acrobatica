"""Test end-to-end del rilevamento automatico piani di facciata.

Gira sulla fixture reale 6cdcb8ff (327 foto ARKit) e confronta il piano
dominante col piano "vero" della facciata principale (true_plane.json,
ottenuto dalla mesh Object Capture — qui usato SOLO come riferimento di
verifica, non dalla pipeline).

Nota storica importante: su questa facciata i pattern ripetitivi (finestre)
generano per triangolazione un piano "fantasma" parallelo ~2 m DAVANTI al
muro vero, con PIÙ inlier del muro vero e track altrettanto lunghe. Nessun
filtro geometrico lo distingue: lo boccia solo la verifica FOTOMETRICA
(verify_planes_photometric, NCC a tessere passa-alto). I test riflettono
questo: il piano dominante è quello col photo_score migliore, non quello
con più inlier.

Lento (~minuti): triangola SIFT su tutte le foto. La pipeline viene eseguita
una sola volta per modulo (fixture scope="module").
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from app.services.facade_planes import (
    detect_planes,
    load_cameras,
    triangulate_session,
    verify_planes_photometric,
)

BACKEND = Path(__file__).resolve().parents[1]
FIXTURE = BACKEND / "data" / "fixtures" / "6cdcb8ff"
TRUE_PLANE = Path(__file__).parent / "data" / "true_plane_6cdcb8ff.json"

pytestmark = pytest.mark.skipif(
    not (FIXTURE / "photos.json").exists(),
    reason="fixture 6cdcb8ff non presente",
)


@pytest.fixture(scope="module")
def pipeline():
    """Triangolazione + RANSAC + verifica fotometrica, una volta per modulo."""
    cloud = triangulate_session(FIXTURE / "photos", FIXTURE / "photos.json")
    raw_planes = detect_planes(cloud.points, camera_centers=cloud.camera_centers)
    cams = load_cameras(FIXTURE / "photos", FIXTURE / "photos.json")
    planes = verify_planes_photometric(raw_planes, cams)
    return cloud, raw_planes, planes


@pytest.fixture(scope="module")
def true_plane() -> dict:
    return json.loads(TRUE_PLANE.read_text())


def test_nuvola_triangolata_e_densa(pipeline):
    cloud, _, _ = pipeline
    # La sessione di riferimento produce ~40k punti; pretendiamo almeno 10k
    # perché il RANSAC multi-piano resti affidabile.
    assert len(cloud.points) > 10_000
    assert float(np.median(cloud.rms_px)) < 2.0


def test_piano_dominante_e_la_facciata_principale(pipeline, true_plane):
    _, _, planes = pipeline
    assert planes, "nessun piano sopravvissuto alla verifica fotometrica"
    main = planes[0]

    n_true = np.asarray(true_plane["n"], dtype=np.float64)
    c_true = np.asarray(true_plane["c"], dtype=np.float64)

    # (a) normale entro 1.5°; profondità entro 25 cm dal riferimento.
    # NB: il muro "fotografico" sta ~12 cm davanti al piano OC (misurato):
    # un offset di quell'ordine è atteso.
    cosang = abs(float(main.n @ n_true))
    angle_deg = float(np.degrees(np.arccos(np.clip(cosang, -1.0, 1.0))))
    dist_m = abs(float((c_true - main.c) @ main.n))
    assert angle_deg < 1.5, f"angolo vs true_plane: {angle_deg:.2f} deg"
    assert dist_m < 0.25, f"distanza centro vero dal piano: {dist_m*100:.1f} cm"

    # Sanity: quasi verticale, estensione da facciata vera, score decente
    assert abs(main.n[1]) < 0.1
    assert main.width_m > 5.0 and main.height_m > 5.0
    assert main.photo_score > 0.4


def test_muro_fantasma_bocciato_dalla_fotometria(pipeline, true_plane):
    """Il piano da match finestra-sbagliata (parallelo, ~2 m davanti, PIÙ
    inlier del muro vero) deve: esistere nel RANSAC grezzo (è il canarino del
    dataset) ed essere ESCLUSO dopo la verifica fotometrica."""
    _, raw_planes, planes = pipeline
    n_true = np.asarray(true_plane["n"], dtype=np.float64)
    c_true = np.asarray(true_plane["c"], dtype=np.float64)

    def is_ghost(p):
        parallel = abs(float(p.n @ n_true)) > np.cos(np.radians(12.0))
        gap = abs(float((p.c - c_true) @ n_true))
        return parallel and 0.5 < gap < 6.0

    assert any(is_ghost(p) for p in raw_planes), (
        "il piano fantasma non compare nemmeno nel RANSAC grezzo: "
        "dataset cambiato? rivedere il test"
    )
    survivors = [p for p in planes if is_ghost(p)]
    assert not survivors, (
        f"muro fantasma sopravvissuto alla fotometria: "
        f"{[(p.n_inliers, round(p.photo_score, 2)) for p in survivors]}"
    )


@pytest.mark.xfail(reason="TODO: il RANSAC non isola ancora la spalletta "
                          "d'angolo (pochi punti triangolati su quel lato); "
                          "richiede coppie dedicate o soglia adattiva")
def test_trova_anche_la_spalletta(pipeline):
    """Facciata principale + spalletta d'angolo: almeno 2 piani veri."""
    _, _, planes = pipeline
    assert len(planes) >= 2, f"trovati solo {len(planes)} piani verificati"
