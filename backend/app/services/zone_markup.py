"""Marcatura zone della facciata (upload dall'editor iOS).

Il documento arriva dall'editor con aree/perimetri già calcolati lato client;
qui li RICALCOLIAMO da punti_px + ppm (fonte di verità server-side) così un
client buggato o un JSON modificato a mano non può sballare il preventivo.

Tipi di zona (rawValue concordati, non cambiarli):
  esclusa | da_rifare | misurabile | nota  → poligoni chiusi (area m²)
  lineare                                  → polilinea aperta (lunghezza m)
"""
from __future__ import annotations

import math

from ..models import MarcaturaZoneDocument, ZonaMarcataModel

TIPI_VALIDI = {"esclusa", "da_rifare", "misurabile", "nota", "lineare"}

# Discrepanza relativa oltre la quale segnaliamo un warning fra i valori
# dichiarati dal client e quelli ricalcolati qui.
_TOLLERANZA_RELATIVA = 0.02


def shoelace_area_px2(punti: list[list[float]]) -> float:
    """Area del poligono chiuso in px² (shoelace, valore assoluto)."""
    if len(punti) < 3:
        return 0.0
    s = 0.0
    n = len(punti)
    for i in range(n):
        ax, ay = punti[i][0], punti[i][1]
        bx, by = punti[(i + 1) % n][0], punti[(i + 1) % n][1]
        s += ax * by - bx * ay
    return abs(s) / 2.0


def path_length_px(punti: list[list[float]], chiusa: bool) -> float:
    """Lunghezza del percorso in px (chiuso per i poligoni, aperto per le linee)."""
    if len(punti) < 2:
        return 0.0
    n = len(punti)
    coppie = range(n) if chiusa else range(n - 1)
    return sum(
        math.hypot(punti[(i + 1) % n][0] - punti[i][0],
                   punti[(i + 1) % n][1] - punti[i][1])
        for i in coppie
    )


def valida_documento(doc: MarcaturaZoneDocument) -> list[str]:
    """Errori bloccanti (lista vuota = documento valido)."""
    errori: list[str] = []
    if doc.ppm <= 0:
        errori.append(f"ppm non valido: {doc.ppm}")
    if doc.larghezza_px <= 0 or doc.altezza_px <= 0:
        errori.append(f"dimensioni non valide: {doc.larghezza_px}x{doc.altezza_px}")
    for i, z in enumerate(doc.zone):
        if z.tipo not in TIPI_VALIDI:
            errori.append(f"zona {i} ('{z.nome}'): tipo sconosciuto '{z.tipo}'")
            continue
        minimo = 2 if z.tipo == "lineare" else 3
        if len(z.punti_px) < minimo:
            errori.append(f"zona {i} ('{z.nome}'): servono almeno {minimo} punti, trovati {len(z.punti_px)}")
        for p in z.punti_px:
            if len(p) < 2:
                errori.append(f"zona {i} ('{z.nome}'): punto malformato {p}")
                break
            if not (-1 <= p[0] <= doc.larghezza_px + 1 and -1 <= p[1] <= doc.altezza_px + 1):
                errori.append(f"zona {i} ('{z.nome}'): punto fuori immagine ({p[0]:.0f},{p[1]:.0f})")
                break
    return errori


def ricalcola_metriche(doc: MarcaturaZoneDocument) -> list[str]:
    """Ricalcola in-place area_m2/perimetro_m di ogni zona da punti_px + ppm.

    Ritorna warning sulle discrepanze rispetto ai valori dichiarati dal client.
    """
    warnings: list[str] = []
    ppm = doc.ppm
    for z in doc.zone:
        lineare = z.tipo == "lineare"
        area = 0.0 if lineare else shoelace_area_px2(z.punti_px) / (ppm * ppm)
        lung = path_length_px(z.punti_px, chiusa=not lineare) / ppm
        if _discrepante(z.area_m2, area) or _discrepante(z.perimetro_m, lung):
            warnings.append(
                f"zona '{z.nome}': metriche client ({z.area_m2:.2f} m², {z.perimetro_m:.2f} m) "
                f"≠ ricalcolate ({area:.2f} m², {lung:.2f} m) — uso le ricalcolate"
            )
        z.area_m2 = area
        z.perimetro_m = lung
    return warnings


def totali_per_tipo(zone: list[ZonaMarcataModel]) -> tuple[dict[str, float], dict[str, float]]:
    """(aree m² per tipo, lunghezze m per tipo lineare). Le zone nascoste
    (visibile=False) sono escluse dai totali: l'operatore le ha "spente"."""
    aree: dict[str, float] = {}
    lunghezze: dict[str, float] = {}
    for z in zone:
        if not z.visibile:
            continue
        if z.tipo == "lineare":
            lunghezze[z.tipo] = lunghezze.get(z.tipo, 0.0) + z.perimetro_m
        else:
            aree[z.tipo] = aree.get(z.tipo, 0.0) + z.area_m2
    return aree, lunghezze


def _discrepante(dichiarato: float, ricalcolato: float) -> bool:
    rif = max(abs(dichiarato), abs(ricalcolato))
    if rif < 1e-9:
        return False
    return abs(dichiarato - ricalcolato) / rif > _TOLLERANZA_RELATIVA
