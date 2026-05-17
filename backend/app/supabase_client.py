"""Inizializzazione lazy del client Supabase (singleton)."""
from __future__ import annotations
from functools import lru_cache

from supabase import Client, create_client

from . import config


@lru_cache(maxsize=1)
def get_supabase() -> Client:
    if not config.SUPABASE_URL or not config.SUPABASE_SERVICE_KEY:
        raise RuntimeError(
            "Mancano le variabili d'ambiente SUPABASE_URL e SUPABASE_SERVICE_KEY"
        )
    return create_client(config.SUPABASE_URL, config.SUPABASE_SERVICE_KEY)
