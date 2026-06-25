# Autodesk Reality Capture API Pipeline

Dataset pilota: `1553ab3c`, Palazzo Adriatica completo, 215 foto.

## Cosa Serve

- Autodesk Platform Services app con Reality Capture API abilitata.
- `APS_CLIENT_ID`
- `APS_CLIENT_SECRET`
- Entitlement/billing ReCap/Flex attivo.

## Input

Il dataset locale e' qui:

```text
/Users/liscio/Acrobatica/backend/data/fixtures/1553ab3c/photos/
```

Bundle preparato:

```text
/Users/liscio/Acrobatica/backend/data/fixtures/1553ab3c_photos.zip
```

## Workflow API

1. Richiedere OAuth token APS.
2. Creare una photoscene.
3. Aggiungere tutte le immagini alla photoscene.
4. Avviare processing.
5. Pollare progress.
6. Recuperare link risultato.
7. Scaricare output in:

```text
/Users/liscio/Acrobatica/backend/data/photogrammetry-runs/1553ab3c/autodesk/
```

## Output Da Richiedere

- OBJ textured mesh.
- RCM, se disponibile.
- RCS/point cloud o output point-cloud equivalente, se disponibile per il tipo scena.

## Variabili Ambiente

```bash
export APS_CLIENT_ID="..."
export APS_CLIENT_SECRET="..."
```

## Run Locale

```bash
cd /Users/liscio/Acrobatica/backend

./venv/bin/python scripts/run_autodesk_reality_capture.py create 1553ab3c
./venv/bin/python scripts/run_autodesk_reality_capture.py upload 1553ab3c
./venv/bin/python scripts/run_autodesk_reality_capture.py launch 1553ab3c
./venv/bin/python scripts/run_autodesk_reality_capture.py progress 1553ab3c
./venv/bin/python scripts/run_autodesk_reality_capture.py result 1553ab3c --format obj
./venv/bin/python scripts/run_autodesk_reality_capture.py result 1553ab3c --format rcm
```

Lo script salva lo stato in:

```text
/Users/liscio/Acrobatica/backend/data/photogrammetry-runs/1553ab3c/autodesk/state.json
```

## Stato Corrente

La pipeline e' pronta, ma il primo comando `create` richiede credenziali Autodesk APS:

```text
APS_CLIENT_ID
APS_CLIENT_SECRET
```

## Nota

Autodesk e' il percorso SaaS: non gestiamo VM/GPU, ma dobbiamo verificare entitlement e consumo Flex/ReCap sul tenant Autodesk.
