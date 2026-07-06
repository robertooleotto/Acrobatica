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
        .limit(1)
        .execute()
    )
    if not res.data:
        return None
    sess = res.data[0]
    return update_status(sess["id"], session_state.COMPUTING_OC)


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
