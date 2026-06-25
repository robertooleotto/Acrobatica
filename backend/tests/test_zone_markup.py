"""Test della logica pura di marcatura zone (validazione + ricalcolo metriche)."""
import pytest

from app.models import MarcaturaZoneDocument, ZonaMarcataModel
from app.services import zone_markup


def _doc(zone, ppm=100.0, w=2000, h=1500):
    return MarcaturaZoneDocument(ppm=ppm, larghezza_px=w, altezza_px=h, zone=zone)


def _quadrato(nome="Z1", tipo="esclusa", lato_px=200.0, visibile=True):
    # 200 px @ 100 ppm = 2 m di lato → 4 m², perimetro 8 m
    return ZonaMarcataModel(
        nome=nome, tipo=tipo, visibile=visibile,
        punti_px=[[100, 100], [100 + lato_px, 100],
                  [100 + lato_px, 100 + lato_px], [100, 100 + lato_px]],
    )


def test_validazione_ok():
    assert zone_markup.valida_documento(_doc([_quadrato()])) == []


def test_validazione_tipo_sconosciuto():
    z = _quadrato(tipo="boh")
    errori = zone_markup.valida_documento(_doc([z]))
    assert len(errori) == 1 and "tipo sconosciuto" in errori[0]


def test_validazione_punti_insufficienti():
    z = ZonaMarcataModel(nome="Z", tipo="esclusa", punti_px=[[0, 0], [10, 10]])
    errori = zone_markup.valida_documento(_doc([z]))
    assert any("almeno 3 punti" in e for e in errori)

    lin = ZonaMarcataModel(nome="L", tipo="lineare", punti_px=[[0, 0]])
    errori = zone_markup.valida_documento(_doc([lin]))
    assert any("almeno 2 punti" in e for e in errori)


def test_validazione_punto_fuori_immagine():
    z = ZonaMarcataModel(nome="Z", tipo="nota",
                         punti_px=[[0, 0], [3000, 0], [0, 100]])
    errori = zone_markup.valida_documento(_doc([z], w=2000, h=1500))
    assert any("fuori immagine" in e for e in errori)


def test_validazione_ppm_non_valido():
    errori = zone_markup.valida_documento(_doc([], ppm=0))
    assert any("ppm" in e for e in errori)


def test_ricalcolo_quadrato():
    doc = _doc([_quadrato()])
    warnings = zone_markup.ricalcola_metriche(doc)
    z = doc.zone[0]
    assert z.area_m2 == pytest.approx(4.0)
    assert z.perimetro_m == pytest.approx(8.0)
    # il client aveva 0/0 → discrepanza segnalata ma valori corretti applicati
    assert len(warnings) == 1


def test_ricalcolo_lineare_polilinea_aperta():
    # L di 300+400 px @ 100 ppm = 7 m; NON chiude il percorso (no +500 px ipotenusa)
    lin = ZonaMarcataModel(nome="Ringhiera", tipo="lineare",
                           punti_px=[[0, 0], [300, 0], [300, 400]],
                           perimetro_m=7.0)
    doc = _doc([lin])
    warnings = zone_markup.ricalcola_metriche(doc)
    assert lin.area_m2 == 0.0
    assert lin.perimetro_m == pytest.approx(7.0)
    assert warnings == []  # valori client coerenti → nessun warning


def test_totali_escludono_zone_nascoste():
    visibile = _quadrato(nome="A", tipo="esclusa")
    nascosta = _quadrato(nome="B", tipo="esclusa", visibile=False)
    lin = ZonaMarcataModel(nome="L", tipo="lineare",
                           punti_px=[[0, 0], [500, 0]])
    doc = _doc([visibile, nascosta, lin])
    zone_markup.ricalcola_metriche(doc)
    aree, lunghezze = zone_markup.totali_per_tipo(doc.zone)
    assert aree == {"esclusa": pytest.approx(4.0)}
    assert lunghezze == {"lineare": pytest.approx(5.0)}
