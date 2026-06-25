"""Pre-marcatura automatica: propone zone "Esclusa" dai punti fuori-piano.

Input: nuvola triangolata della sessione (facade_planes.triangulate_session)
+ piano facciata principale (formato to_dict: c, n, up, right, bounds).

Pipeline:
  1. δ = distanza con segno dal piano (positiva VERSO le camere, perché la
     normale è orientata verso di esse): sporgenze tipo balconi/aggetti.
  2. Punti con δ > soglia (default 0.15 m) dentro i bounds del piano.
  3. Occupancy grid sul piano (celle in metri) → morfologia di chiusura →
     contorni cv2 → poligoni semplificati.
  4. Poligoni convertiti in pixel ortofoto con la convenzione v22:
       x_px = (u − u_min) · ppm
       y_px = (v_max − v) · ppm      (origine in alto a sinistra)

Le zone proposte sono nello schema dell'editor iOS (tipo "esclusa") e vanno
intese come BOZZE che l'operatore conferma o ritocca.
"""
from __future__ import annotations

import cv2
import numpy as np

from ..models import MarcaturaZoneDocument, ZonaMarcataModel
from . import zone_markup

SOGLIA_DELTA_M = 0.15      # aggetti oltre 15 cm dal piano
CELLA_M = 0.20             # lato cella dell'occupancy grid
MIN_PUNTI_CELLA = 3        # punti minimi perché una cella conti
MIN_AREA_M2 = 0.30         # zone più piccole sono rumore
MAX_ZONE = 20


def proponi_zone(
    points: np.ndarray,
    plane: dict,
    *,
    ppm: float,
    soglia_m: float = SOGLIA_DELTA_M,
    cella_m: float = CELLA_M,
    min_punti_cella: int = MIN_PUNTI_CELLA,
    min_area_m2: float = MIN_AREA_M2,
    max_zone: int = MAX_ZONE,
    solo_sporgenze: bool = True,
) -> MarcaturaZoneDocument:
    """Costruisce il documento di marcatura con le zone fuori-piano proposte.

    `solo_sporgenze=False` include anche le rientranze (|δ| > soglia), utile
    per logge incassate — di default no, per non marcare porte/finestre.
    """
    if ppm <= 0:
        raise ValueError(f"ppm non valido: {ppm}")
    P = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    c = np.asarray(plane["c"], dtype=np.float64)
    n = np.asarray(plane["n"], dtype=np.float64)
    up = np.asarray(plane["up"], dtype=np.float64)
    right = np.asarray(plane["right"], dtype=np.float64)
    u_min, u_max, v_min, v_max = (float(b) for b in plane["bounds"])

    larghezza_px = max(1, int(round((u_max - u_min) * ppm)))
    altezza_px = max(1, int(round((v_max - v_min) * ppm)))
    doc = MarcaturaZoneDocument(ppm=ppm, larghezza_px=larghezza_px,
                                altezza_px=altezza_px, zone=[])
    if len(P) == 0:
        return doc

    rel = P - c
    delta = rel @ n
    u = rel @ right
    v = rel @ up
    fuori = delta > soglia_m if solo_sporgenze else np.abs(delta) > soglia_m
    dentro = (u >= u_min) & (u <= u_max) & (v >= v_min) & (v <= v_max)
    sel = fuori & dentro
    if not np.any(sel):
        return doc

    # Occupancy grid: riga 0 = v_min (la conversione a y_px inverte dopo).
    nu = max(1, int(np.ceil((u_max - u_min) / cella_m)))
    nv = max(1, int(np.ceil((v_max - v_min) / cella_m)))
    iu = np.clip(((u[sel] - u_min) / cella_m).astype(int), 0, nu - 1)
    iv = np.clip(((v[sel] - v_min) / cella_m).astype(int), 0, nv - 1)
    conta = np.zeros((nv, nu), dtype=np.int32)
    np.add.at(conta, (iv, iu), 1)
    mask = (conta >= min_punti_cella).astype(np.uint8) * 255
    if not mask.any():
        return doc

    # Chiusura morfologica: salda i buchi di una cella dentro lo stesso aggetto.
    kernel = np.ones((3, 3), dtype=np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)

    contorni, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    candidate: list[tuple[float, np.ndarray]] = []
    for cont in contorni:
        area_m2 = cv2.contourArea(cont) * cella_m * cella_m
        if area_m2 < min_area_m2:
            continue
        # Semplifica a ~1 cella di tolleranza; i vertici sono in celle (x=iu, y=iv).
        approx = cv2.approxPolyDP(cont, epsilon=1.0, closed=True).reshape(-1, 2)
        if len(approx) < 3:
            continue
        candidate.append((area_m2, approx))

    candidate.sort(key=lambda t: -t[0])
    for k, (_, poly_celle) in enumerate(candidate[:max_zone], start=1):
        punti_px: list[list[float]] = []
        for cx, cy in poly_celle:
            # Centro cella → coordinate piano (m). +0.5: il contorno passa per
            # i centri delle celle occupate, il mezzo passo evita di "mangiare"
            # mezzo bordo su ogni lato.
            pu = u_min + (float(cx) + 0.5) * cella_m
            pv = v_min + (float(cy) + 0.5) * cella_m
            x_px = (pu - u_min) * ppm
            y_px = (v_max - pv) * ppm
            punti_px.append([
                float(np.clip(x_px, 0, larghezza_px)),
                float(np.clip(y_px, 0, altezza_px)),
            ])
        doc.zone.append(ZonaMarcataModel(
            nome=f"Aggetto {k} (auto)",
            tipo="esclusa",
            visibile=True,
            punti_px=punti_px,
        ))

    zone_markup.ricalcola_metriche(doc)
    return doc
