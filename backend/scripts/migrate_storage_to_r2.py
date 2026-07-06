#!/usr/bin/env python3
# migrate_storage_to_r2.py — Migra i file (foto + mesh) da Supabase Storage a
# Cloudflare R2, prendendo l'elenco dai path registrati nel DB.
#
# Resumable: salta i file già presenti su R2 (HEAD). Parallelo. Idempotente.
# Legge Supabase (sorgente) e R2 (destinazione) direttamente, a prescindere da
# STORAGE_BACKEND. Dopo la migrazione, con STORAGE_BACKEND=s3 tutto è servito da R2.
#
# Uso:  python -m scripts.migrate_storage_to_r2 [--photos] [--mesh] [--workers 8]
#       (default: entrambi)
import argparse, sys
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, ".")
from app import config
from app.supabase_client import get_supabase
from app.services import storage_service as ss

_CT = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
       ".obj": "model/obj", ".mtl": "model/mtl", ".usdz": "model/vnd.usdz+zip",
       ".json": "application/json", ".ply": "application/octet-stream"}


def content_type(path: str) -> str:
    import os
    return _CT.get(os.path.splitext(path)[1].lower(), "application/octet-stream")


def gather_paths(photos: bool, mesh: bool) -> list[str]:
    c = get_supabase()
    paths: set[str] = set()
    if photos:
        # PostgREST limita a 1000 righe/richiesta → paginazione con range().
        start, page = 0, 1000
        while True:
            rows = (c.table("facade_photos").select("storage_path")
                    .range(start, start + page - 1).execute().data)
            if not rows:
                break
            paths.update(r["storage_path"] for r in rows if r.get("storage_path"))
            if len(rows) < page:
                break
            start += page
    if mesh:
        rows = c.table("facade_sessions").select("result").execute().data
        for r in rows:
            m = (r.get("result") or {}).get("mesh") or {}
            groups = [m] if "files" in m else m.values()   # piatto o {raw,clean}
            for g in groups:
                for f in (g or {}).get("files", []):
                    p = f.get("path") if isinstance(f, dict) else None
                    if p:
                        paths.add(p)
    return sorted(paths)


def migrate_one(path: str) -> tuple[str, str]:
    """Ritorna (path, esito): 'skip' | 'ok' | 'err: …'."""
    r2 = ss._s3()
    try:
        r2.head_object(Bucket=config.S3_BUCKET, Key=path)
        return path, "skip"          # già su R2
    except Exception:
        pass
    try:
        data = get_supabase().storage.from_(config.SUPABASE_BUCKET).download(path)
        r2.put_object(Bucket=config.S3_BUCKET, Key=path, Body=data,
                      ContentType=content_type(path))
        return path, "ok"
    except Exception as e:
        return path, f"err: {str(e)[:80]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--photos", action="store_true")
    ap.add_argument("--mesh", action="store_true")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()
    photos = args.photos or not (args.photos or args.mesh)
    mesh = args.mesh or not (args.photos or args.mesh)

    if config.STORAGE_BACKEND.lower() != "s3":
        sys.exit("STORAGE_BACKEND non è 's3': configura R2 nel .env prima.")

    paths = gather_paths(photos, mesh)
    print(f"da migrare: {len(paths)} file (photos={photos}, mesh={mesh})")
    done = {"ok": 0, "skip": 0, "err": 0}
    errors = []
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(migrate_one, p): p for p in paths}
        for i, fut in enumerate(as_completed(futs), 1):
            p, esito = fut.result()
            key = "ok" if esito == "ok" else ("skip" if esito == "skip" else "err")
            done[key] += 1
            if key == "err":
                errors.append((p, esito))
            if i % 100 == 0 or i == len(paths):
                print(f"  {i}/{len(paths)}  ok={done['ok']} skip={done['skip']} err={done['err']}")
    print(f"FATTO — migrati {done['ok']}, già presenti {done['skip']}, errori {done['err']}")
    for p, e in errors[:10]:
        print("  ERR", p, e)


if __name__ == "__main__":
    main()
