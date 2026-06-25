"""Run the Reali3 photogrammetry API on a local fixture.

SCHELETRO — da completare con gli endpoint reali una volta ricevuti chiave e
documentazione da Reali3 (https://reali3.net/contact). Il flusso documentato è:
  1. Get API key (dashboard).
  2. Upload images/video all'endpoint.
  3. Processing automatico.
  4. Download model (OBJ/PLY/GLTF/LAS).

I punti marcati `# TODO(docs)` vanno allineati al payload/endpoint reali: nomi dei
campi, path, schema della risposta. La struttura (fixture, stato, subset) è
identica a run_autodesk_reality_capture.py per coerenza.

Prerequisiti:
    export REALI3_API_KEY="..."          # dalla dashboard Reali3
    # opzionale, se la base URL differisce da quella di default:
    export REALI3_BASE_URL="https://api.reali3.net/v1"

Esempi:
    ./venv/bin/python scripts/run_reali3.py create 6cdcb8ff
    ./venv/bin/python scripts/run_reali3.py upload 6cdcb8ff --max-photos 80
    ./venv/bin/python scripts/run_reali3.py status 6cdcb8ff
    ./venv/bin/python scripts/run_reali3.py download 6cdcb8ff --format obj
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "data" / "fixtures"
RUNS = ROOT / "data" / "photogrammetry-runs"

# TODO(docs): confermare la base URL reale dalla documentazione Reali3.
BASE_URL = os.getenv("REALI3_BASE_URL", "https://api.reali3.net/v1")

load_dotenv(ROOT / ".env")


def fail(message: str) -> None:
    raise SystemExit(message)


def api_key() -> str:
    key = os.getenv("REALI3_API_KEY")
    if not key:
        fail("Manca REALI3_API_KEY. Mettila in backend/.env e riesegui.")
    return key


def headers() -> dict[str, str]:
    # TODO(docs): confermare lo schema di auth (Bearer vs header custom es. X-API-Key).
    return {"Authorization": f"Bearer {api_key()}", "Accept": "application/json"}


def resolve_fixture(arg: str) -> Path:
    path = Path(arg)
    if not path.is_absolute():
        direct = ROOT / path
        path = direct if direct.exists() else FIXTURES / arg
    if not (path / "photos.json").exists():
        fail(f"Fixture non trovata o incompleta: {path}")
    return path.resolve()


def state_path(dataset: str) -> Path:
    return RUNS / dataset / "reali3" / "state.json"


def load_state(dataset: str) -> dict[str, Any]:
    p = state_path(dataset)
    if p.exists():
        return json.loads(p.read_text(encoding="utf-8"))
    return {"dataset": dataset, "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ")}


def save_state(dataset: str, state: dict[str, Any]) -> None:
    p = state_path(dataset)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(state, indent=2), encoding="utf-8")
    print(f"State: {p}")


def get_photos(fixture: Path, max_photos: int = 0) -> list[dict[str, Any]]:
    photos = json.loads((fixture / "photos.json").read_text(encoding="utf-8"))
    photos = sorted(photos, key=lambda p: int(p["order_index"]))
    if max_photos and len(photos) > max_photos:
        step = len(photos) / max_photos
        photos = [photos[int(i * step)] for i in range(max_photos)]
        print(f"Sottocampionamento: {max_photos} foto uniformi.")
    return photos


def api(method: str, path: str, **kwargs: Any) -> dict[str, Any]:
    h = kwargs.pop("headers", {})
    h.update(headers())
    res = requests.request(method, BASE_URL + path, headers=h, timeout=120, **kwargs)
    if not res.ok:
        fail(f"Reali3 API error {method} {path}: HTTP {res.status_code}\n{res.text[:2000]}")
    if not res.text.strip():
        return {}
    try:
        return res.json()
    except ValueError:
        return {"raw": res.text}


def create_job(dataset: str) -> None:
    state = load_state(dataset)
    # TODO(docs): endpoint + payload reali per creare un job di ricostruzione.
    body = api("POST", "/jobs", json={"name": f"acrobatica-{dataset}"})
    job_id = body.get("id") or body.get("job_id")  # TODO(docs): nome campo reale
    if not job_id:
        fail(f"Job creato ma id non trovato:\n{json.dumps(body, indent=2)}")
    state.update({"job_id": job_id, "create_response": body})
    save_state(dataset, state)
    print(f"Job: {job_id}")


def upload(fixture: Path, max_photos: int) -> None:
    dataset = fixture.name
    state = load_state(dataset)
    job_id = state.get("job_id")
    if not job_id:
        fail("Manca job_id. Esegui prima: create")
    photos = get_photos(fixture, max_photos)
    uploaded = state.get("uploaded", [])
    done = {int(x["order_index"]) for x in uploaded if "order_index" in x}
    for photo in photos:
        order = int(photo["order_index"])
        if order in done:
            continue
        local = fixture / photo["storage_path"]
        if not local.exists():
            fail(f"File mancante: {local}")
        print(f"Upload {order:04d}: {local.name}")
        with local.open("rb") as fh:
            # TODO(docs): endpoint upload + nome campo file + come si lega al job.
            files = {"file": (local.name, fh, "image/jpeg")}
            body = api("POST", f"/jobs/{job_id}/images", files=files)
        uploaded.append({"order_index": order, "file": local.name, "response": body})
        state["uploaded"] = uploaded
        save_state(dataset, state)
    print("Upload completato.")


def start(dataset: str) -> None:
    state = load_state(dataset)
    job_id = state.get("job_id")
    if not job_id:
        fail("Manca job_id. Esegui prima: create")
    # TODO(docs): alcune API avviano in automatico dopo l'upload; altre hanno un /start.
    body = api("POST", f"/jobs/{job_id}/process")
    state["start_response"] = body
    save_state(dataset, state)
    print("Processing avviato.")


def status(dataset: str) -> None:
    state = load_state(dataset)
    job_id = state.get("job_id")
    if not job_id:
        fail("Manca job_id.")
    body = api("GET", f"/jobs/{job_id}")
    state["last_status"] = body
    save_state(dataset, state)
    print(json.dumps(body, indent=2))


def download(dataset: str, fmt: str) -> None:
    state = load_state(dataset)
    job_id = state.get("job_id")
    if not job_id:
        fail("Manca job_id.")
    # TODO(docs): endpoint download + come si specifica il formato (query? path?).
    body = api("GET", f"/jobs/{job_id}/model", params={"format": fmt})
    link = body.get("url") or body.get("download_url")  # TODO(docs): campo reale
    if not link:
        fail(f"Risposta download senza link:\n{json.dumps(body, indent=2)[:2000]}")
    out_dir = RUNS / dataset / "reali3" / "downloads"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{dataset}.{fmt}"
    print(f"Download {fmt}: {link}")
    with requests.get(link, stream=True, timeout=300) as res:
        res.raise_for_status()
        with out.open("wb") as fh:
            for chunk in res.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    fh.write(chunk)
    print(f"Salvato: {out} ({out.stat().st_size / 1024 / 1024:.1f} MB)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("create", "upload", "start", "status", "download"))
    parser.add_argument("dataset", help="fixture id, es. 6cdcb8ff")
    parser.add_argument("--max-photos", type=int, default=0, help="campiona N foto (0 = tutte)")
    parser.add_argument("--format", default="obj", choices=("obj", "ply", "gltf", "las"))
    args = parser.parse_args()

    fixture = resolve_fixture(args.dataset)
    dataset = fixture.name

    if args.command == "create":
        create_job(dataset)
    elif args.command == "upload":
        upload(fixture, args.max_photos)
    elif args.command == "start":
        start(dataset)
    elif args.command == "status":
        status(dataset)
    elif args.command == "download":
        download(dataset, args.format)


if __name__ == "__main__":
    sys.path.insert(0, str(ROOT))
    main()
