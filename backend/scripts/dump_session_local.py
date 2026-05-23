"""Scarica una sessione Supabase in locale come "fixture" riutilizzabile per
test offline.  Salva foto + metadata in formato identico a quello che
`session_store.list_photos()` ritorna, così i run script (keystone, ortho)
possono leggerlo come se fosse Supabase senza modifiche.

Layout output:
    backend/data/fixtures/<session_id_short>/
      session.json     # riga della sessione (status, result, …)
      photos.json      # array di { order_index, storage_path, metadata }
      photos/
        0001.jpg
        0002.jpg
        …

Uso:
    python scripts/dump_session_local.py <session_id_prefix>
"""
from __future__ import annotations
import sys, json
from pathlib import Path
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from dotenv import load_dotenv
load_dotenv(ROOT / ".env")

from app.services import session_store, storage_service
from app.supabase_client import get_supabase


def resolve(prefix: str) -> dict:
    res = get_supabase().table("facade_sessions").select("*").execute()
    matches = [r for r in (res.data or []) if r["id"].startswith(prefix)]
    if not matches: raise SystemExit(f"Nessuna sessione con prefisso {prefix}")
    if len(matches) > 1:
        raise SystemExit(f"Prefisso ambiguo: {[m['id'] for m in matches]}")
    return matches[0]


def main(prefix: str) -> None:
    sess = resolve(prefix)
    sid = sess["id"]
    short = sid[:8]
    out_dir = ROOT / "data" / "fixtures" / short
    photos_dir = out_dir / "photos"
    photos_dir.mkdir(parents=True, exist_ok=True)

    photos = session_store.list_photos(sid)
    print(f"Sessione: {sid}")
    print(f"Foto:     {len(photos)}")
    print(f"Output:   {out_dir}")

    # Session row (rimuoviamo created_at dict di serializzazione, restano stringhe)
    (out_dir / "session.json").write_text(
        json.dumps({**sess, "id": sid}, indent=2, default=str), encoding="utf-8"
    )

    # Photos: scarica JPEG + costruisci JSON array con storage_path locale.
    photos_out: list[dict] = []
    for p in photos:
        order = p["order_index"]
        ext = Path(p["storage_path"]).suffix or ".jpg"
        local_name = f"{order:04d}{ext}"
        local_path = photos_dir / local_name
        try:
            raw = storage_service.download_bytes(p["storage_path"])
            local_path.write_bytes(raw)
            print(f"  [{order:>2}] {len(raw)//1024} KB → {local_name}")
        except Exception as e:
            print(f"  [{order:>2}] download FALLITO: {e}")
            continue
        # Sostituiamo storage_path con percorso RELATIVO al fixture dir
        photos_out.append({
            **p,
            "storage_path_remote": p["storage_path"],
            "storage_path": f"photos/{local_name}",   # relativo a out_dir
            "dumped_at": datetime.utcnow().isoformat() + "Z",
        })
    (out_dir / "photos.json").write_text(
        json.dumps(photos_out, indent=2, default=str), encoding="utf-8"
    )

    print(f"\nDump completato.")
    print(f"Per riusarlo:")
    print(f"  python scripts/run_ortho_local.py --fixture {out_dir}")
    print(f"  python scripts/run_keystone_local.py --fixture {out_dir}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Uso: python scripts/dump_session_local.py <session_id_prefix>")
    main(sys.argv[1])
