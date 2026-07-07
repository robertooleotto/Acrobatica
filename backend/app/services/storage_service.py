"""Storage dei file di sessione (foto/mesh/texture), con backend intercambiabile.

Backend selezionato da `config.STORAGE_BACKEND`:
  - "supabase" (default): Supabase Storage (bucket `facade-photos`). Limite ~50MB/file.
  - "s3": qualunque object storage S3-compatibile — **Cloudflare R2** (consigliato),
    Backblaze B2, Wasabi… Nessun limite pratico + egress gratis su R2.

Il DB (sessioni/metadati) resta su Supabase Postgres in ogni caso. I path sono
identici tra i backend, quindi si può migrare cambiando solo la env STORAGE_BACKEND
(e caricando i file su R2). Layout:
    sessions/<session_id>/photos/<order_index>.jpg
    sessions/<session_id>/out/mesh/<kind>/<name>
"""
from __future__ import annotations

import functools

from .. import config


def photo_path(session_id: str, order_index: int, ext: str = "jpg") -> str:
    return f"sessions/{session_id}/photos/{order_index:04d}.{ext}"


def out_path(session_id: str, name: str) -> str:
    return f"sessions/{session_id}/out/{name}"


def _use_s3() -> bool:
    return config.STORAGE_BACKEND.lower() == "s3"


@functools.lru_cache(maxsize=1)
def _s3():
    import boto3
    from botocore.config import Config
    from urllib.parse import urlparse
    # Endpoint = solo scheme://host: se l'utente ha incollato anche /<bucket> in
    # coda (errore comune con R2), lo togliamo → niente doppio bucket nel path.
    p = urlparse((config.S3_ENDPOINT_URL or "").strip())
    endpoint = f"{p.scheme}://{p.netloc}" if p.scheme and p.netloc else config.S3_ENDPOINT_URL
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=config.S3_ACCESS_KEY_ID,
        aws_secret_access_key=config.S3_SECRET_ACCESS_KEY,
        region_name=config.S3_REGION,
        config=Config(signature_version="s3v4"),
    )


def _supabase_bucket():
    from ..supabase_client import get_supabase
    return get_supabase().storage.from_(config.SUPABASE_BUCKET)


def upload_bytes(remote_path: str, data: bytes, content_type: str = "image/jpeg") -> None:
    if _use_s3():
        _s3().put_object(Bucket=config.S3_BUCKET, Key=remote_path,
                         Body=data, ContentType=content_type)
        return
    _supabase_bucket().upload(
        path=remote_path,
        file=data,
        file_options={"content-type": content_type, "upsert": "true"},
    )


def download_bytes(remote_path: str) -> bytes:
    if _use_s3():
        return _s3().get_object(Bucket=config.S3_BUCKET, Key=remote_path)["Body"].read()
    return _supabase_bucket().download(remote_path)


def head_size(remote_path: str) -> int | None:
    """Dimensione in byte del file su storage senza scaricarlo (HEAD su S3/R2),
    o None se non esiste/non raggiungibile. Su Supabase non c'è un HEAD economico
    → ripiega su download (raro ora che il backend di produzione è S3)."""
    if _use_s3():
        try:
            return int(_s3().head_object(Bucket=config.S3_BUCKET, Key=remote_path)["ContentLength"])
        except Exception:
            return None
    try:
        return len(_supabase_bucket().download(remote_path))
    except Exception:
        return None


def signed_url(remote_path: str, expires_in_sec: int | None = None) -> str:
    ttl = expires_in_sec or config.SIGNED_URL_TTL_SEC
    if _use_s3():
        return _s3().generate_presigned_url(
            "get_object",
            Params={"Bucket": config.S3_BUCKET, "Key": remote_path},
            ExpiresIn=ttl,
        )
    res = _supabase_bucket().create_signed_url(remote_path, ttl)
    # supabase-py 2.x ritorna {'signedURL': '...', 'signedUrl': '...'}; copriamo entrambi.
    return res.get("signedURL") or res.get("signedUrl") or ""
