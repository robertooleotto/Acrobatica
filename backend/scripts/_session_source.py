"""Wrapper che fornisce ai run-script l'accesso uniforme a `(photos, get_image)`
da Supabase OPPURE da una fixture locale dumpata via `dump_session_local.py`.

Uso:
    src = SessionSource.open(arg)   # arg = session_id_prefix OR path/to/fixture
    for p in src.photos:
        img = src.load_image(p)
"""
from __future__ import annotations
import json
from pathlib import Path
from dataclasses import dataclass

import cv2
import numpy as np


@dataclass
class SessionSource:
    sid: str
    photos: list[dict]
    _is_fixture: bool
    _fixture_dir: Path | None = None

    @staticmethod
    def open(arg: str) -> "SessionSource":
        path = Path(arg)
        if path.is_dir() and (path / "photos.json").exists():
            return SessionSource._from_fixture(path)
        # Altrimenti tratta come session_id_prefix
        from app.services import session_store
        from app.supabase_client import get_supabase
        res = get_supabase().table("facade_sessions").select("id").execute()
        matches = [r["id"] for r in (res.data or []) if r["id"].startswith(arg)]
        if not matches: raise SystemExit(f"Nessuna sessione con prefisso {arg}")
        if len(matches) > 1: raise SystemExit(f"Prefisso ambiguo: {matches}")
        sid = matches[0]
        photos = session_store.list_photos(sid)
        return SessionSource(sid=sid, photos=photos, _is_fixture=False)

    @staticmethod
    def _from_fixture(path: Path) -> "SessionSource":
        photos = json.loads((path / "photos.json").read_text(encoding="utf-8"))
        sess = json.loads((path / "session.json").read_text(encoding="utf-8"))
        return SessionSource(
            sid=sess["id"], photos=photos,
            _is_fixture=True, _fixture_dir=path,
        )

    def load_image(self, photo: dict) -> np.ndarray | None:
        if self._is_fixture:
            local = self._fixture_dir / photo["storage_path"]
            return cv2.imread(str(local), cv2.IMREAD_COLOR)
        else:
            from app.services import storage_service
            raw = storage_service.download_bytes(photo["storage_path"])
            return cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)

    @property
    def source_label(self) -> str:
        return f"fixture {self._fixture_dir}" if self._is_fixture else f"supabase {self.sid}"
