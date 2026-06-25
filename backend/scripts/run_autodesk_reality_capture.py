"""Run Autodesk Reality Capture API on a local fixture/Supabase session.

This script uses Supabase signed URLs instead of uploading image bytes from the
Mac. Autodesk fetches the images from those temporary URLs.

Prerequisites:
    export APS_CLIENT_ID="..."
    export APS_CLIENT_SECRET="..."

Examples:
    ./venv/bin/python scripts/run_autodesk_reality_capture.py create 1553ab3c
    ./venv/bin/python scripts/run_autodesk_reality_capture.py upload 1553ab3c
    ./venv/bin/python scripts/run_autodesk_reality_capture.py launch 1553ab3c
    ./venv/bin/python scripts/run_autodesk_reality_capture.py progress 1553ab3c
    ./venv/bin/python scripts/run_autodesk_reality_capture.py result 1553ab3c --format obj
    ./venv/bin/python scripts/run_autodesk_reality_capture.py download 1553ab3c --format obj
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
BASE_URL = "https://developer.api.autodesk.com/photo-to-3d/v1"

load_dotenv(ROOT / ".env")


def fail(message: str) -> None:
    raise SystemExit(message)


def resolve_fixture(arg: str) -> Path:
    path = Path(arg)
    if not path.is_absolute():
        direct = ROOT / path
        path = direct if direct.exists() else FIXTURES / arg
    if not (path / "photos.json").exists():
        fail(f"Fixture non trovata o incompleta: {path}")
    return path.resolve()


def state_path(dataset: str) -> Path:
    return RUNS / dataset / "autodesk" / "state.json"


def load_state(dataset: str) -> dict[str, Any]:
    path = state_path(dataset)
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"dataset": dataset, "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ")}


def save_state(dataset: str, state: dict[str, Any]) -> None:
    path = state_path(dataset)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2), encoding="utf-8")
    print(f"State: {path}")


def aps_token() -> str:
    client_id = os.getenv("APS_CLIENT_ID") or os.getenv("FORGE_CLIENT_ID")
    client_secret = os.getenv("APS_CLIENT_SECRET") or os.getenv("FORGE_CLIENT_SECRET")
    if not client_id or not client_secret:
        fail(
            "Mancano APS_CLIENT_ID/APS_CLIENT_SECRET. "
            "Creali in Autodesk Platform Services e riesegui il comando."
        )

    # Reality Capture API examples historically use the v1 endpoint. Try v2
    # first, then fall back to v1 for older tenants/API compatibility.
    scopes = "data:read data:write"
    try:
        res = requests.post(
            "https://developer.api.autodesk.com/authentication/v2/token",
            data={"grant_type": "client_credentials", "scope": scopes},
            auth=(client_id, client_secret),
            timeout=30,
        )
        if res.ok:
            return res.json()["access_token"]
    except requests.RequestException:
        pass

    res = requests.post(
        "https://developer.api.autodesk.com/authentication/v1/authenticate",
        data={
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "client_credentials",
            "scope": scopes.replace(" ", "+"),
        },
        timeout=30,
    )
    if not res.ok:
        fail(f"OAuth fallito: HTTP {res.status_code}\n{res.text[:1000]}")
    return res.json()["access_token"]


def autodesk_request(method: str, path: str, token: str, **kwargs: Any) -> dict[str, Any]:
    headers = kwargs.pop("headers", {})
    headers.update({"Authorization": f"Bearer {token}", "Accept": "application/json"})
    res = requests.request(method, BASE_URL + path, headers=headers, timeout=120, **kwargs)
    if not res.ok:
        fail(f"Autodesk API error {method} {path}: HTTP {res.status_code}\n{res.text[:2000]}")
    if not res.text.strip():
        return {}
    try:
        return res.json()
    except ValueError:
        return {"raw": res.text}


def get_photos(fixture: Path, max_photos: int = 0) -> list[dict[str, Any]]:
    photos = json.loads((fixture / "photos.json").read_text(encoding="utf-8"))
    photos = sorted(photos, key=lambda p: int(p["order_index"]))
    if max_photos and len(photos) > max_photos:
        # campionamento uniforme: mantiene la copertura lungo la facciata
        step = len(photos) / max_photos
        photos = [photos[int(i * step)] for i in range(max_photos)]
        print(f"Sottocampionamento: {max_photos} foto su {len(json.loads((fixture / 'photos.json').read_text(encoding='utf-8')))}")
    return photos


def supabase_signed_urls(photos: list[dict[str, Any]], ttl_sec: int) -> list[str]:
    from app.services import storage_service

    urls: list[str] = []
    for photo in photos:
        remote = photo.get("storage_path_remote")
        if not remote:
            remote = f"sessions/{photo['session_id']}/photos/{int(photo['order_index']):04d}.jpg"
        urls.append(storage_service.signed_url(remote, expires_in_sec=ttl_sec))
    return urls


def create_scene(dataset: str, scene_name: str, formats: str, scene_type: str) -> None:
    token = aps_token()
    state = load_state(dataset)
    data = {
        "scenename": scene_name,
        "format": formats,
        "scenetype": scene_type,
    }
    body = autodesk_request("POST", "/photoscene", token, data=data)
    photoscene = body.get("Photoscene") or body.get("photoscene") or body
    scene_id = photoscene.get("photosceneid") or photoscene.get("photosceneID")
    if not scene_id:
        fail(f"Photoscene creata ma ID non trovato nella risposta:\n{json.dumps(body, indent=2)}")
    state.update(
        {
            "photosceneid": scene_id,
            "scene_name": scene_name,
            "formats": formats,
            "scene_type": scene_type,
            "create_response": body,
        }
    )
    save_state(dataset, state)
    print(f"Photoscene: {scene_id}")


def upload_urls(fixture: Path, batch_size: int, ttl_sec: int, max_photos: int = 0) -> None:
    dataset = fixture.name
    state = load_state(dataset)
    scene_id = state.get("photosceneid")
    if not scene_id:
        fail("Manca photosceneid nello state. Esegui prima: create")
    token = aps_token()
    photos = get_photos(fixture, max_photos)
    urls = supabase_signed_urls(photos, ttl_sec=ttl_sec)
    uploaded = []
    for start in range(0, len(urls), batch_size):
        batch = urls[start : start + batch_size]
        data: dict[str, str] = {"photosceneid": scene_id, "type": "image"}
        for i, url in enumerate(batch):
            data[f"file[{i}]"] = url
        print(f"Upload URL {start + 1}-{start + len(batch)} / {len(urls)}")
        body = autodesk_request("POST", "/file", token, data=data)
        uploaded.append({"start": start, "count": len(batch), "response": body})
        state["upload_batches"] = uploaded
        save_state(dataset, state)
    print("Upload completato.")


def launch(dataset: str) -> None:
    state = load_state(dataset)
    scene_id = state.get("photosceneid")
    if not scene_id:
        fail("Manca photosceneid nello state. Esegui prima: create")
    token = aps_token()
    body = autodesk_request("POST", f"/photoscene/{scene_id}", token, data={})
    state["launch_response"] = body
    save_state(dataset, state)
    print("Processing avviato.")


def progress(dataset: str) -> None:
    state = load_state(dataset)
    scene_id = state.get("photosceneid")
    if not scene_id:
        fail("Manca photosceneid nello state.")
    token = aps_token()
    body = autodesk_request("GET", f"/photoscene/{scene_id}/progress", token)
    state["last_progress"] = body
    save_state(dataset, state)
    print(json.dumps(body, indent=2))


def result(dataset: str, fmt: str) -> None:
    state = load_state(dataset)
    scene_id = state.get("photosceneid")
    if not scene_id:
        fail("Manca photosceneid nello state.")
    token = aps_token()
    body = autodesk_request("GET", f"/photoscene/{scene_id}", token, params={"format": fmt})
    state.setdefault("results", {})[fmt] = body
    save_state(dataset, state)
    print(json.dumps(body, indent=2))


def upload_files(fixture: Path, max_photos: int = 0) -> None:
    dataset = fixture.name
    state = load_state(dataset)
    scene_id = state.get("photosceneid")
    if not scene_id:
        fail("Manca photosceneid nello state. Esegui prima: create")
    token = aps_token()
    photos = get_photos(fixture, max_photos)
    uploaded = state.get("uploaded_files", [])
    done = {int(item["order_index"]) for item in uploaded if "order_index" in item}
    last_order = int(photos[-1]["order_index"])
    for photo in photos:
        order = int(photo["order_index"])
        if order in done:
            continue
        local = fixture / photo["storage_path"]
        if not local.exists():
            fail(f"File locale mancante: {local}")
        print(f"Upload file {order:04d} / {last_order:04d}: {local.name}")
        with local.open("rb") as fh:
            files = {"file[0]": (local.name, fh, "image/jpeg")}
            data = {"photosceneid": scene_id, "type": "image"}
            body = autodesk_request("POST", "/file", token, data=data, files=files)
        uploaded.append({"order_index": order, "file": local.name, "response": body})
        state["uploaded_files"] = uploaded
        save_state(dataset, state)
    print("Upload file completato.")


def _extract_scene_link(body: dict[str, Any]) -> str | None:
    scene = body.get("Photoscene") or body.get("photoscene") or body
    link = scene.get("scenelink") or scene.get("sceneLink") or scene.get("url")
    if link:
        return str(link)
    for value in scene.values():
        if isinstance(value, str) and value.startswith(("http://", "https://")):
            return value
    return None


def download_result(dataset: str, fmt: str) -> None:
    state = load_state(dataset)
    token = aps_token()
    scene_id = state.get("photosceneid")
    if not scene_id:
        fail("Manca photosceneid nello state.")
    body = autodesk_request("GET", f"/photoscene/{scene_id}", token, params={"format": fmt})
    link = _extract_scene_link(body)
    state.setdefault("results", {})[fmt] = body
    save_state(dataset, state)
    if not link:
        fail(f"Risultato {fmt} senza link scaricabile:\n{json.dumps(body, indent=2)[:2000]}")

    out_dir = RUNS / dataset / "autodesk" / "downloads"
    out_dir.mkdir(parents=True, exist_ok=True)
    suffix = ".zip"
    if "." in link.rsplit("/", 1)[-1]:
        suffix = "." + link.rsplit(".", 1)[-1].split("?", 1)[0]
    out = out_dir / f"{dataset}_{fmt}{suffix}"
    print(f"Download {fmt}: {link}")
    with requests.get(link, stream=True, timeout=300) as res:
        if not res.ok:
            fail(f"Download fallito: HTTP {res.status_code}\n{res.text[:1000]}")
        with out.open("wb") as fh:
            for chunk in res.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    fh.write(chunk)
    print(f"Salvato: {out} ({out.stat().st_size / 1024 / 1024:.1f} MB)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=(
            "create",
            "upload",
            "upload-files",
            "launch",
            "progress",
            "result",
            "download",
        ),
    )
    parser.add_argument("dataset", help="fixture id, e.g. 1553ab3c")
    parser.add_argument("--scene-name", default=None)
    parser.add_argument("--formats", default="obj,rcm")
    parser.add_argument("--scene-type", default="object")
    parser.add_argument("--batch-size", type=int, default=40)
    parser.add_argument("--ttl-sec", type=int, default=7 * 24 * 3600)
    parser.add_argument("--format", default="obj")
    parser.add_argument("--max-photos", type=int, default=0,
                        help="campiona N foto uniformemente (0 = tutte)")
    args = parser.parse_args()

    fixture = resolve_fixture(args.dataset)
    dataset = fixture.name

    if args.command == "create":
        scene_name = args.scene_name or f"acrobatica-{dataset}"
        create_scene(dataset, scene_name, args.formats, args.scene_type)
    elif args.command == "upload":
        upload_urls(fixture, args.batch_size, args.ttl_sec, args.max_photos)
    elif args.command == "upload-files":
        upload_files(fixture, args.max_photos)
    elif args.command == "launch":
        launch(dataset)
    elif args.command == "progress":
        progress(dataset)
    elif args.command == "result":
        result(dataset, args.format)
    elif args.command == "download":
        download_result(dataset, args.format)


if __name__ == "__main__":
    sys.path.insert(0, str(ROOT))
    main()
