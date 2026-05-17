"""CRUD sessioni/foto su Postgres tramite supabase-py."""
from __future__ import annotations
from typing import Optional

from ..supabase_client import get_supabase

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
