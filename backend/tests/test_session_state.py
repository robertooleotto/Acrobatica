"""Test della macchina a stati della sessione (puro, senza DB)."""
import pytest

from app.services import session_state as st


def test_happy_path_completo():
    """Il percorso lineare del prodotto è interamente percorribile."""
    for a, b in zip(st.FLOW, st.FLOW[1:]):
        assert st.can_transition(a, b), f"{a} → {b} dovrebbe essere valida"


def test_transizione_idempotente():
    for s in st.FLOW:
        assert st.can_transition(s, s)


def test_salti_non_validi():
    # non si salta dalla cattura direttamente alla mesh o alla stesura
    assert not st.can_transition(st.CAPTURING, st.MESH_READY)
    assert not st.can_transition(st.UPLOADED, st.COMPLETED)
    assert not st.can_transition(st.MESH_READY, st.MAPPING)


def test_fail_da_ogni_stadio_di_lavoro():
    for s in [st.UPLOADING, st.QUEUED_OC, st.COMPUTING_OC, st.MESH_READY,
              st.CLEANING, st.PLANES_READY, st.MAPPING]:
        assert st.can_transition(s, st.FAILED), f"{s} → failed deve valere"


def test_retry_da_failed():
    # dopo un fallimento del calcolo si può ri-accodare
    assert st.can_transition(st.FAILED, st.QUEUED_OC)
    # e ripulire di nuovo la mesh
    assert st.can_transition(st.FAILED, st.CLEANING)


def test_riedita_da_completed():
    # a documento steso si può tornare a pulire la mesh o ri-stendere
    assert st.can_transition(st.COMPLETED, st.CLEANING)
    assert st.can_transition(st.COMPLETED, st.MAPPING)


def test_primo_risultato_automatico_puo_saltare_la_pulizia():
    assert st.can_transition(st.MESH_READY, st.PLANES_READY)


def test_validate_solleva():
    with pytest.raises(ValueError):
        st.validate_transition(st.CAPTURING, "boh")
    with pytest.raises(ValueError):
        st.validate_transition(st.UPLOADED, st.COMPLETED)
    # valida non solleva sul percorso giusto
    st.validate_transition(st.UPLOADED, st.QUEUED_OC)


def test_next_stage():
    assert st.next_stage(st.CAPTURING) == st.UPLOADING
    assert st.next_stage(st.MAPPING) == st.COMPLETED
    assert st.next_stage(st.COMPLETED) is None


def test_progress_monotono():
    vals = [st.progress(s) for s in st.FLOW]
    assert vals[0] == 0.0 and vals[-1] == 1.0
    assert all(b >= a for a, b in zip(vals, vals[1:])), "progresso non monotono"
