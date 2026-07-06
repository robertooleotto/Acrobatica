"""Configurazione centralizzata via variabili d'ambiente."""
from __future__ import annotations
import os
from dotenv import load_dotenv

load_dotenv()

SUPABASE_URL: str | None = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_KEY: str | None = os.environ.get("SUPABASE_SERVICE_KEY")
SUPABASE_BUCKET: str = os.environ.get("SUPABASE_BUCKET", "facade-photos")

# Backend di storage per i FILE (foto/mesh/texture): "supabase" (default) o "s3"
# (S3-compatibile: Cloudflare R2, Backblaze B2, Wasabi…). Il DB resta su Supabase.
# R2 = niente limite ~50MB, egress gratis → adatto ai GB di mesh/texture.
STORAGE_BACKEND: str = os.environ.get("STORAGE_BACKEND", "supabase")
S3_ENDPOINT_URL: str | None = os.environ.get("S3_ENDPOINT_URL")       # R2: https://<account>.r2.cloudflarestorage.com
S3_ACCESS_KEY_ID: str | None = os.environ.get("S3_ACCESS_KEY_ID")
S3_SECRET_ACCESS_KEY: str | None = os.environ.get("S3_SECRET_ACCESS_KEY")
S3_BUCKET: str = os.environ.get("S3_BUCKET", SUPABASE_BUCKET)
S3_REGION: str = os.environ.get("S3_REGION", "auto")                  # R2 vuole "auto"

# Tempo di vita dei signed URL per le immagini servite all'app iOS.
SIGNED_URL_TTL_SEC: int = int(os.environ.get("SIGNED_URL_TTL_SEC", "3600"))
