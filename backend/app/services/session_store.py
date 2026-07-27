"""CRUD sessioni/foto su Postgres tramite supabase-py."""
from __future__ import annotations
from typing import Optional

from ..supabase_client import get_supabase
from . import session_state

SESSIONS = "facade_sessions"
PHOTOS = "facade_photos"


def create_session(name: str = "") -> dict:
    client = get_supabase()
    res = client.table(SESSIONS).insert({"name": name, "status": "capturing"}).execute()
    return res.data[0]


def get_session(session_id: str) -> Optional[dict]:
    client = get_supabase()
    res = client.table(SESSIONS).select("*").eq("id", session_id).limit(1).execute()
    return res.data[0] if res.data else None


def update_session(session_id: str, fields: dict) -> dict:
    client = get_supabase()
    res = client.table(SESSIONS).update(fields).eq("id", session_id).execute()
    return res.data[0]


def update_status(session_id: str, to: str) -> dict:
    """Transiziona la sessione a `to` validando la transizione dallo stato corrente.
    Solleva ValueError se la transizione non è ammessa (la macchina a stati è la
    fonte di verità). Idempotente se `to` == stato corrente."""
    sess = get_session(session_id)
    if sess is None:
        raise KeyError(session_id)
    frm = sess.get("status") or ""
    session_state.validate_transition(frm, to)
    if frm == to:
        return sess
    return update_session(session_id, {"status": to})


def claim_next_oc_job() -> Optional[dict]:
    """Prende la sessione più vecchia in `queued_oc` e la prenota (→ computing_oc).
    Opzione A = un solo worker → nessuna corsa. Ritorna la riga aggiornata o None
    se la coda è vuota."""
    client = get_supabase()
    res = (
        client.table(SESSIONS)
        .select("*")
        .eq("status", session_state.QUEUED_OC)
        .order("created_at")
        .limit(16)
        .execute()
    )
    for sess in res.data or []:
        # Compare-and-swap: con piu' worker solo uno puo' cambiare queued_oc.
        claimed = (
            client.table(SESSIONS)
            .update({"status": session_state.COMPUTING_OC})
            .eq("id", sess["id"])
            .eq("status", session_state.QUEUED_OC)
            .execute()
        )
        if claimed.data:
            return claimed.data[0]
    return None


def next_queued_projection_job() -> Optional[dict]:
    """Trova il job di proiezione piu' vecchio in attesa del worker Mac.

    Come la coda Object Capture, questa installazione usa un solo worker. Il
    passaggio a ``running`` viene scritto immediatamente dal chiamante prima di
    restituire gli URL firmati.
    """
    client = get_supabase()
    res = (
        client.table(SESSIONS)
        .select("*")
        .contains("result", {"projection_job": {"state": "queued"}})
        .order("updated_at")
        .limit(1)
        .execute()
    )
    for sess in res.data or []:
        job = ((sess.get("result") or {}).get("projection_job") or {})
        if job.get("state") == "queued" and job.get("job_id"):
            return sess
    return None


def claim_next_projection_job(job_update: dict) -> Optional[dict]:
    """Claim atomico del bake tramite filtro JSONB compare-and-swap.

    `job_update` e' il documento `projection_job` gia' portato a running. Il
    filtro include stato e job_id precedenti: due worker possono leggere lo
    stesso candidato, ma soltanto il primo aggiornamento viene applicato.
    """
    client = get_supabase()
    res = (
        client.table(SESSIONS)
        .select("*")
        .contains("result", {"projection_job": {"state": "queued"}})
        .order("updated_at")
        .limit(8)
        .execute()
    )
    for sess in res.data or []:
        result = sess.get("result") or {}
        previous = result.get("projection_job") or {}
        job_id = previous.get("job_id")
        if previous.get("state") != "queued" or not job_id:
            continue
        updated_result = {**result, "projection_job": {
            **job_update,
            "job_id": job_id,
            "started_at": previous.get("started_at") or job_update.get("updated_at"),
        }}
        claimed = (
            client.table(SESSIONS)
            .update({"result": updated_result})
            .eq("id", sess["id"])
            .contains("result", {"projection_job": {
                "state": "queued", "job_id": job_id,
            }})
            .execute()
        )
        if claimed.data:
            return claimed.data[0]
    return None


def upsert_photo(session_id: str, order_index: int, storage_path: str, metadata: dict) -> dict:
    client = get_supabase()
    res = client.table(PHOTOS).upsert(
        {
            "session_id": session_id,
            "order_index": order_index,
            "storage_path": storage_path,
            "metadata": metadata,
        },
        on_conflict="session_id,order_index",
    ).execute()
    return res.data[0]


def list_photos(session_id: str) -> list[dict]:
    client = get_supabase()
    res = (
        client.table(PHOTOS)
        .select("*")
        .eq("session_id", session_id)
        .order("order_index")
        .execute()
    )
    return res.data
