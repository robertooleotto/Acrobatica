# Pipeline Object Capture → mesh texturizzata web → piani → ortofoto

Stato: codice consolidato dal lavoro in sessione. La parte di **calcolo Object
Capture su Mac remoto** ("il computer che fa il calcolo") è **rimandata** — qui la
pipeline parte dall'`usdz` già prodotto.

Sessione di riferimento: `6cdcb8ff` (palazzo "Riunione Adriatica", 327 foto iPhone).
Dati di lavoro (NON nel repo, troppo grandi): `~/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/`.
Foto + pose ARKit: `backend/data/fixtures/6cdcb8ff/` (`photos/`, `photos.json`).

---

## Stadi

### 0. (RIMANDATO) Calcolo Object Capture → `model.usdz`
Gira su **Mac Apple Silicon** (`PhotogrammetrySession`, dettaglio `.raw` per geometria
densa). Tool e runbook: `HelloPhotogrammetry.swift`, `README.md`. Il "ponte" col Mac
che esegue il calcolo è **fuori scope per ora**. Input alla pipeline = l'`usdz`.

Promemoria detail level: `.full` NON aumenta i triangoli (dettaglio in displacement
map); per geometria densa serve **`.raw`** (~793k tri, 2 pagine texture 8K).

### 1. `usdz` → `GLB` (visualizzazione web texturizzata) ✅
```bash
python usdz_to_glb.py model_raw.usdz -o model_raw_webgl_flipv.glb --flip-v
npx --yes @gltf-transform/cli validate model_raw_webgl_flipv.glb   # no errors
```
- Headless (pxr/usd-core), niente Blender.
- Splitta i vertici per `(pointIdx, stIdx, normalIdx)` (UV `primvars:st` faceVarying
  indicizzate → indice unico glTF), una **primitiva per GeomSubset** (Group→tex0,
  Group_1→tex1), texture PNG **embedded** in bufferView. `--flip-v` per three.js.
- Reso da `GLTFLoader` **nitido come usdrecord**. Viewer: `viewer_glb.html`
  (`python3 -m http.server 8781` poi `?file=model_raw_webgl_flipv.glb`).
- PERCHÉ GLB e non OBJ: l'OBJ texturizzato in three.js "impasta" (atlante a isole
  minuscole + UV faceVarying mal gestite dal path OBJ). Il GLB con indici unificati
  risolve. `usdrecord` (nativo Apple) è il riferimento di qualità.

### 2. `usdz` → `OBJ` + UV native (per elaborazioni Python) ✅
```bash
python usd_to_obj.py model_raw.usdz . model_raw_usd
```
Legge punti + UV ORIGINALI via pxr (NON ModelI/O), facce `f v/vt` raggruppate per
pagina. Usato per bake/analisi lato Python.

### 3. (DA INTEGRARE) Editor web dei piani
Mostrare il GLB (stadio 1) con `GLTFLoader`, l'utente **clicca/crea le facce** (piani).
Base editor: `plane_rebuild_*.html` (logica di picking/region-growing già esistente,
opera sulla geometria). TODO: caricare il GLB e fondere le 2 primitive in un'unica
geometria per il raycasting; export piani in JSON.

### 4. Proiezione foto → mesh (colori per vertice) ✅
```bash
python project_photos_to_mesh.py --mesh model_nobbox.obj \
  --poses oc_poses_nobbox.json --photos .../fixtures/6cdcb8ff/photos \
  --out model_nobbox_photo.ply
```
Pose OC dirette (niente Umeyama/RANSAC), occlusione via raycast Open3D, best-view per
vertice. ~20s, ~99% copertura. Output morbido (per-vertice) — utile come layer "Foto".

### 5. Proiezione foto → piani (ortofoto per faccia) ✅ (esistente)
`project_planes_photos.py` (nella working dir): dai piani del JSON (stadio 3), proietta
le foto sul piano piatto, best-view per pixel, inpaint dei buchi → ortofoto per ogni
poligono. È la **ri-texturizzazione** delle facce.

### 6. Camera projection in WebGL (riproiezione foto, no UV) ✅
Riproietta le foto sulla geometria/sul piano **dalla camera che le ha scattate** (stile
Maya/3ds Max), senza usare le UV → niente deformazione da UV. Viewer in `web/`
(`camera_projection_multi.html`, `oc_projection_compare.html`) + **auto-align robusto**
di `shiftX/shiftY/focalScale` per foto. Dettagli, math e procedura:
**`HANDOFF_camera_projection.md`**. TODO: occlusione (depth dal proiettore) e
proiezione sul piano liscio.

---

## Note per il backend

- **Dipendenze pesanti** (`usd-core`, `open3d`, `opencv`): vedi `requirements.txt`.
  Non metterle sul web dyno principale — usare un **worker/immagine dedicata** o un job
  asincrono. Lo stadio 1 (usdz→glb) richiede solo `usd-core` (leggero), eseguibile
  anche in un job on-demand all'upload dell'usdz.
- **Frame metrico**: la mesh `.raw` è in un frame OC proprio **senza pose foto**; le
  pose foto esistono per `nobbox` (`oc_poses_nobbox.json`). Per ri-texturizzare la mesh
  densa servirà allinearla a nobbox (ICP) o rigenerare le pose. (Anche questo lato
  "ponte/calcolo" è rimandato.)
- **Storage**: usdz/glb/texture (centinaia di MB) → object storage, non nel repo né nel
  DB. Servire il GLB al frontend via URL firmato.

## File in questa cartella
- `usdz_to_glb.py` — stadio 1 (canonico). `viewer_glb.html` — viewer GLTFLoader.
- `usd_to_obj.py` — stadio 2 (UV native).
- `project_photos_to_mesh.py` — stadio 4.
- `HelloPhotogrammetry.swift`, `usdz2obj.swift`, `usdz_to_editor.py` — tool stadio 0 /
  conversioni alternative (ModelI/O — texture impasta in web, tenuti per riferimento).
- `requirements.txt`, `README.md` (runbook noleggio Mac).
