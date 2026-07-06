"""Macchina a stati della sessione di rilievo facciata — flusso prodotto a 8 passi.

Modulo PURO (nessun accesso a DB/rete): definisce gli stadi, il flusso lineare e
le transizioni valide. È la singola fonte di verità su "a che punto è la sessione".
Testabile in isolamento (tests/test_session_state.py).

Flusso prodotto:
    capturing → uploading → uploaded          (1–2: app scatta e carica)
    uploaded → queued_oc → computing_oc → mesh_ready   (3–4: calcolo su Mac cloud)
    mesh_ready → cleaning → clean_uploaded     (6: pulizia mesh on-device)
    clean_uploaded → planes_ready              (7: piani puliti)
    planes_ready → mapping → completed         (8: proiezione foto→piani, stesura)

Da `failed` si può rientrare per ritentare lo stadio che ha fallito.
"""
from __future__ import annotations

# ── Stadi ────────────────────────────────────────────────────────────────────
CAPTURING = "capturing"
UPLOADING = "uploading"
UPLOADED = "uploaded"
QUEUED_OC = "queued_oc"
COMPUTING_OC = "computing_oc"
MESH_READY = "mesh_ready"
CLEANING = "cleaning"
CLEAN_UPLOADED = "clean_uploaded"
PLANES_READY = "planes_ready"
MAPPING = "mapping"
COMPLETED = "completed"
FAILED = "failed"
PROCESSING = "processing"  # legacy pipeline 2D

# Percorso lineare "happy path" del prodotto.
FLOW: list[str] = [
    CAPTURING, UPLOADING, UPLOADED,
    QUEUED_OC, COMPUTING_OC, MESH_READY,
    CLEANING, CLEAN_UPLOADED, PLANES_READY,
    MAPPING, COMPLETED,
]

# Stadi da cui non si prosegue automaticamente.
TERMINAL = {COMPLETED, FAILED}

# Ogni stadio da cui il lavoro può fallire (→ FAILED, con retry).
_RETRYABLE = {UPLOADING, UPLOADED, QUEUED_OC, COMPUTING_OC, MESH_READY,
              CLEANING, CLEAN_UPLOADED, PLANES_READY, MAPPING, PROCESSING}

# ── Transizioni valide ───────────────────────────────────────────────────────
# forward = passo successivo del flusso; più alcune back-edge intenzionali:
#  - mesh_ready/completed → cleaning: ri-editare la mesh
#  - planes_ready → mapping → completed, e completed → mapping: ri-stendere
#  - queued_oc → uploaded: annullare/riaccodare
_ALLOWED: dict[str, set[str]] = {
    CAPTURING:      {UPLOADING, UPLOADED, PROCESSING},
    UPLOADING:      {UPLOADED, UPLOADING},
    UPLOADED:       {QUEUED_OC, UPLOADING},
    QUEUED_OC:      {COMPUTING_OC, UPLOADED},
    COMPUTING_OC:   {MESH_READY, QUEUED_OC},
    MESH_READY:     {CLEANING},
    CLEANING:       {CLEAN_UPLOADED, CLEANING},
    CLEAN_UPLOADED: {PLANES_READY, CLEANING},
    PLANES_READY:   {MAPPING, CLEANING},
    MAPPING:        {COMPLETED, MAPPING},
    COMPLETED:      {CLEANING, MAPPING},      # ri-edita mesh o ri-stendi
    PROCESSING:     {COMPLETED},              # legacy 2D
    FAILED:         set(),                    # popolato sotto (retry)
}

# Da FAILED si ritenta lo stadio precedente: consentiamo il rientro verso ogni
# stadio retryable (il chiamante sa quale stava eseguendo).
_ALLOWED[FAILED] = set(_RETRYABLE) | {CAPTURING}

# Ogni stadio retryable può andare in FAILED.
for _s in _RETRYABLE:
    _ALLOWED.setdefault(_s, set()).add(FAILED)


def is_valid(status: str) -> bool:
    """True se `status` è uno stadio noto."""
    return status in _ALLOWED


def can_transition(frm: str, to: str) -> bool:
    """True se la transizione frm→to è ammessa. Idempotente (frm==to sempre ok)."""
    if frm == to:
        return True
    return to in _ALLOWED.get(frm, set())


def validate_transition(frm: str, to: str) -> None:
    """Solleva ValueError se la transizione non è valida."""
    if not is_valid(to):
        raise ValueError(f"Stato sconosciuto: {to!r}")
    if not is_valid(frm):
        # sessione con stato legacy/ignoto: consenti solo di ripartire in avanti
        raise ValueError(f"Stato di partenza sconosciuto: {frm!r}")
    if not can_transition(frm, to):
        raise ValueError(f"Transizione non valida: {frm} → {to}")


def next_stage(frm: str) -> str | None:
    """Prossimo stadio del percorso lineare, o None se terminale/ignoto."""
    if frm in FLOW:
        i = FLOW.index(frm)
        if i + 1 < len(FLOW):
            return FLOW[i + 1]
    return None


def progress(status: str) -> float:
    """Avanzamento 0..1 lungo il flusso (per barre di stato lato app)."""
    if status == COMPLETED:
        return 1.0
    if status in FLOW:
        return FLOW.index(status) / (len(FLOW) - 1)
    return 0.0
