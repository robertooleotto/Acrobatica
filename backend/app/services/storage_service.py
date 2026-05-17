"""Wrapper sopra Supabase Storage per upload/download dei file della sessione.

Layout dei path nel bucket `facade-photos`:
    sessions/<session_id>/photos/<order_index>.jpg
    sessions/<session_id>/out/stitched.jpg
    sessions/<session_id>/out/rectified.jpg
"""
from __future__ import annotations

from .. import config
from ..supabase_client import get_supabase


def photo_path(session_id: str, order_index: int, ext: str = "jpg") -> str:
    return f"sessions/{session_id}/photos/{order_index:04d}.{ext}"


def out_path(session_id: str, name: str) -> str:
    return f"sessions/{session_id}/out/{name}"


def upload_bytes(remote_path: str, data: bytes, content_type: str = "image/jpeg") -> None:
    client = get_supabase()
    bucket = client.storage.from_(config.SUPABASE_BUCKET)
    bucket.upload(
        path=remote_path,
        file=data,
        file_options={"content-type": content_type, "upsert": "true"},
    )


def download_bytes(remote_path: str) -> bytes:
    client = get_supabase()
    bucket = client.storage.from_(config.SUPABASE_BUCKET)
    return bucket.download(remote_path)


def signed_url(remote_path: str, expires_in_sec: int | None = None) -> str:
    client = get_supabase()
    bucket = client.storage.from_(config.SUPABASE_BUCKET)
    ttl = expires_in_sec or config.SIGNED_URL_TTL_SEC
    res = bucket.create_signed_url(remote_path, ttl)
    # supabase-py 2.x ritorna {'signedURL': '...', 'signedUrl': '...'}; copriamo entrambi.
    return res.get("signedURL") or res.get("signedUrl") or ""
