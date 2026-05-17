"""Configurazione centralizzata via variabili d'ambiente."""
from __future__ import annotations
import os
from dotenv import load_dotenv

load_dotenv()

SUPABASE_URL: str | None = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_KEY: str | None = os.environ.get("SUPABASE_SERVICE_KEY")
SUPABASE_BUCKET: str = os.environ.get("SUPABASE_BUCKET", "facade-photos")

# Tempo di vita dei signed URL per le immagini servite all'app iOS.
SIGNED_URL_TTL_SEC: int = int(os.environ.get("SIGNED_URL_TTL_SEC", "3600"))
