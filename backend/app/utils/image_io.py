"""Helper per leggere/scrivere lo stato sessione su disco.

Layout:
  data/sessions/<session_id>/
    session.json
    photos/
    out/
"""
from __future__ import annotations
import json
from pathlib import Path
from typing import Optional

from ..models import SessionState

DATA_ROOT = Path(__file__).resolve().parent.parent.parent / "data"


def session_dir(session_id: str) -> Path:
    return DATA_ROOT / "sessions" / session_id


def photos_dir(session_id: str) -> Path:
    return session_dir(session_id) / "photos"


def out_dir(session_id: str) -> Path:
    return session_dir(session_id) / "out"


def session_json(session_id: str) -> Path:
    return session_dir(session_id) / "session.json"


def write_session(state: SessionState) -> None:
    p = session_json(state.session_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(state.model_dump_json(indent=2))


def read_session(session_id: str) -> Optional[SessionState]:
    p = session_json(session_id)
    if not p.is_file():
        return None
    return SessionState.model_validate_json(p.read_text())
