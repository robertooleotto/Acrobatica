# Acrobatica Backend

FastAPI + OpenCV per stitching, rettifica e misurazione di facciate da foto.

## Setup locale

```bash
cd backend
python3.12 -m venv venv
source venv/bin/activate
pip install -r requirements-dev.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Docs interattive: http://localhost:8000/docs
Test: `python -m pytest tests/`

## Esporre il backend in giro (per iPhone fuori dalla rete del Mac)

Per il demo cliente serve un URL pubblico HTTPS che inoltri al tuo Mac. Uso il
tunnel temporaneo di Cloudflare:

```bash
cloudflared tunnel --url http://localhost:8000
```

In stdout cerca una riga tipo `https://random-words-here.trycloudflare.com` — è
l'URL pubblico. **Cambia ad ogni nuovo avvio del tunnel**, quindi:

1. Avvia `uvicorn` come sopra.
2. In un altro terminale: `cloudflared tunnel --url http://localhost:8000`.
3. Copia l'URL `*.trycloudflare.com` dall'output.
4. Aggiorna `ios/Acrobatica/Networking/BackendAPIClient.swift` (campo `baseURL`).
5. In Xcode: Cmd+R per ribuilder l'app.

Limiti: l'URL è effimero (no DNS stabile), bandwidth basso, no SLA — adatto per
demo on-the-go. Per produzione vera, deploy su VPS.

## Endpoint principali

- `POST /facade-sessions` — crea una sessione di scansione, restituisce `session_id`.
- `POST /facade-sessions/{session_id}/photos` — upload di una foto con metadata ARKit.
- `POST /facade-sessions/{session_id}/process` — esegue stitching + rettifica + segmentazione.
- `GET  /facade-sessions/{session_id}/result` — risultato (URL immagine, poligoni, m² pixel).
- `GET  /facade-sessions/{session_id}/files/{filename}` — serve immagini generate.

## Pipeline

1. **Stitching** (`services/stitching_service.py`): `cv2.Stitcher` in modalità PANORAMA con fallback ORB+findHomography per scatti ravvicinati.
2. **Rettifica** (`services/rectification_service.py`): da 4 punti (forniti) o automatica via Hough + vanishing points.
3. **Segmentazione** (`services/segmentation_service.py`): mock per ora; YOLO/SAM in futuro.
4. **Misurazione** (`services/measurement_service.py`): area in pixel quadrati. Conversione metri quando l'app fornisce scaleFactor.

## Storage

Sessioni in `data/sessions/<session_id>/`:
- `photos/` — foto originali + metadata JSON
- `out/` — stitched, rectified, debug
- `session.json` — stato + risultati
