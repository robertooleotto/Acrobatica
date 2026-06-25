# MODUS OPERANDI — Acquisizione e Modellazione facciate (Acrobatica)

> Documento di riferimento operativo. Copre l'intero flusso: **dallo scatto della foto
> → al modello 3D / piano piatto metrico → alla modellazione e alla texture misurabile**.
> Versione **2.0 — 2026-06-05**.

---

## ⭐ SVOLTA v2.0 — Object Capture locale con allineamento NATIVO pixel-accurato

> **TL;DR:** abbiamo una via **locale (sul Mac), metrica e pixel-accurata** dalla foto al
> modello texturizzato, **senza GPU cloud e senza alcun allineamento a posteriori**. Per la
> prima volta le foto cadono **al pixel** sulla geometria (residuo misurato **0 px**). Questo
> **supera** la lotta Meshroom/2DGS/ICP per l'obiettivo *texture-per-le-metriche*.

### Il problema storico (risolto)
Apple Object Capture (OC) produce due output in **frame diversi**:
- **mesh** in *Model Space* (Apple la ri-centra sull'origine e riorienta a gravità);
- **pose camera** in *Session Space* (spazio di tracking).

Per giorni abbiamo provato a ricucirli a posteriori (ICP sulla nuvola triangolata, PCA,
azimut-only): ogni metodo lasciava **8–30 cm di slittamento** → texture spappolata. Causa: la
nuvola triangolata è un **proxy rumoroso**, e due ricostruzioni indipendenti non combaciano
sotto la somma dei loro rumori.

### La soluzione (validata sui fatti, sessione 5563)
Tre cose insieme:
1. **Eseguire `.modelFile` e `.poses` nella STESSA `PhotogrammetrySession`** → mesh, pose e
   intrinseci **coerenti per costruzione** (stesso identico frame).
2. **Configurazione corretta** della sessione Swift:
   ```swift
   var config = PhotogrammetrySession.Configuration()
   config.sampleOrdering        = .sequential
   config.featureSensitivity    = .high
   config.ignoreBoundingBox     = true     // non ritagliare alla bounding box
   config.isObjectMaskingEnabled = false   // è una SCENA, non un oggetto da mascherare
   // poi: session.process(requests: [ .modelFile(url:detail:.full), .poses ])
   ```
3. **Applicare il principal point (cx, cy)** nella proiezione — era questo l'unico "scarto"
   (≈42 px verticali) che sembrava un disallineamento di frame e invece NON lo era.

### Convenzione di proiezione (mondo → pixel) — CONFERMATA
```
R   = quat(rotation_wxyz)          # camera→world (real=w, imag=x,y,z)
Pc  = R.T @ (V - C)                # world→camera (C = translation = centro camera)
depth = -Pc[2]                     # la camera guarda -Z
u   = fx * (Pc[0] / -Pc[2]) + cx   # NIENTE flip di Y
v   = fy * (Pc[1] / -Pc[2]) + cy   # cx,cy OBBLIGATORI (≈970,678 a 1920×1440)
```
Immagini caricate **grezze** (1920×1440, niente EXIF). Intrinseci **già alla risoluzione reale**
(NON riscalare). Occlusione: **z-buffer per pixel** (senza, i vertici del retro "spruzzano").

### Verifiche fatte (prova quantitativa)
- Render della mesh **dalla posa OC nativa** vs foto reale → bordi (Canny) **coincidenti**,
  offset residuo **dx=0, dy=0 px** dopo aver applicato il principal point.
- **La mesh OC NON è in scala metrica** (la sua unità è arbitraria). ⚠️ *Errore corretto:* un
  ICP mesh↔nuvola-triangolata dava scala ≈0,97, ma è **auto-referenziale** (la nuvola nasce
  dalle stesse pose OC) → **non** dimostra la metricità. La scala vera si ottiene **solo** con
  un'àncora esterna: le **pose ARKit metriche** salvate dall'app (vedi sotto). Mesh e pose OC
  sono però nello **stesso identico frame interno** (proiezione 0 px), quindi basta **una sola
  scala** per metricizzare tutto.
- **Calibrazione metrica OC (metodo)** — confronto pose OC ↔ pose ARKit (stesse foto, per
  `order_index`):
  - scala robusta `s = median( |Δcentro_ARKit| / |Δcentro_OC| )` tra scatti consecutivi
    (invariante a rotazione/traslazione), oppure **Umeyama** sui centri-camera;
  - esempio sessione 5563: **s ≈ 3,1 m/unità OC** (std 0,16; percorso ARKit 28,9 m vs OC 9,31 u).
    → edificio ~4,4 m, **altezza di scatto ≈ 1,65 m** (coerente con persona col telefono).
  - le pose ARKit stanno in `facade_photos.metadata.camera_transform` (Supabase), 16 float
    column-major, centro = elementi [12,13,14]. **Sempre** usare questa àncora per la scala.

### Trappole imparate (NON ripeterle)
- **Spray di punti senza occlusione** = visualizzazione fuorviante: sembra disallineato anche
  quando è corretto. Giudicare SEMPRE con **render-da-posa + confronto bordi**, non con i punti.
- **Dimenticare cx,cy** nel render/proiezione → shift sistematico (~40 px) scambiato per bug.
- **ICP con scala (`with_scaling=True`) su nuvola con outlier** → **collassa** la mesh (scala
  0.13 fasulla, "fitness 1.0"). Se si usa ICP: **filtrare gli outlier** (raggio dalle camere +
  rimozione statistica) e **fissare la scala** (ICP rigido). Ma con OC nativo **l'ICP non serve**.
- **`ignoreBoundingBox` NON sposta la mesh dall'origine** (empiricamente resta centrata): il suo
  effetto utile è in combinazione con l'estrazione pose nella stessa sessione. Conta il
  **risultato misurato** (0 px), non quale flag lo produca.

### Pipeline locale OC (riproducibile)
1. Cartella input **pulita** con solo le foto numerate (evita pose doppie da campioni extra).
2. `octool_nobbox.swift` → `model.usdz` + `oc_poses.json` (mesh+pose **stessa sessione**).
   Tempo: ~**10–11 min** per 91 foto, detail `full`, su Intel Mac + Radeon Pro 5500M (8 GB).
3. `usdz2obj.swift` (ModelIO) → `model.obj` (+ texture PNG). *(Open3D 0.19 via ASSIMP NON legge
   questo OBJ per via della riga `o`/`g`: parsare `v`/`f` a mano.)*
4. Ri-proiezione foto → texture/ortofoto pulita (FASE 3), **usando le pose native**.

> **Implicazione di prodotto:** per catture *ben fatte* (oggetto/edificio girato a 360°, buona
> sovrapposizione), questa via locale **sostituisce** Meshroom/pod per generare il modello
> texturizzato misurabile. Meshroom/2DGS restano utili solo per casi specifici (vedi FASE 2.B).

---

## Struttura dell'app (stato attuale)

```
ACROBATICA
├─ iOS (SwiftUI + ARKit + RealityKit)
│  ├─ Capture/ARFacadeCaptureManager.swift   cattura ARKit: pose+intrinseci per foto,
│  │                                          auto-scatto su movimento, esposizione custom
│  ├─ Screens/CatturaARView.swift             UI cattura + guida di copertura (CoverageStrip)
│  ├─ Models/CapturedFacadePhoto.swift        modello foto (pose, intrinseci, order_index)
│  ├─ Models/FacadeCaptureSession.swift       sessione di cattura
│  ├─ DesignSystem/Components/CaptureMatchAnalyzer.swift   analisi qualità/overlap scatti
│  └─ Networking/BackendAPIClient.swift       BackgroundUploader (upload robusto, resume)
│
├─ Backend (Python / FastAPI + Supabase, deploy Railway)
│  ├─ app/services/orthorectify_service.py    WallPlane, fit piano (RANSAC), ortofoto
│  ├─ app/services/rectify_facade.py          rettifica 2D a 4 tap (fallback)
│  ├─ app/services/strip_composite_service.py compositing + MultiBand blend
│  └─ scripts/                                 pipeline offline (vedi Appendice A)
│
├─ Modellazione 3D LOCALE (Mac) — ⭐ via principale per la texture metrica
│  ├─ octool_nobbox.swift     OC: mesh.usdz + oc_poses.json nella STESSA sessione
│  ├─ usdz2obj.swift          USDZ → OBJ (+ texture) via ModelIO
│  ├─ build_session_cloud_*.py nuvola di sessione (solo se serve ICP di controllo)
│  ├─ align_mesh_icp.py       ICP di controllo (filtro outlier + scala fissa) — opzionale
│  └─ proiezione/verifica     render-da-posa, confronto bordi, ri-proiezione texture
│
└─ Modellazione 3D GPU (pod, opzionale) — casi specifici
   ├─ run_meshroom_pipeline.sh  MVS metrico (pose-prior ARKit + rescale Umeyama)
   └─ 2D Gaussian Splatting     fotometrico (dataset COLMAP da pose ARKit)
```

**Tre frame/spazi da non confondere:**
1. **ARKit world** dell'app (gravità Y-up) — pose salvate per foto, usate per piano/ortofoto e
   per il rescale metrico di Meshroom/2DGS.
2. **OC Session Space** — pose restituite da Object Capture (coerenti con la mesh OC).
3. **OC Model Space** — frame nativo della mesh OC. *Con la pipeline v2.0 (mesh+pose nella stessa
   sessione) i frame 2–3 sono già coerenti: nessun ponte da calcolare.*

---

## 0. Filosofia generale

Due mondi, con filosofie **opposte**, che qui combiniamo:

- **Proiezione su piano (leggera, robusta, metrica):** la facciata è modellata come un
  **unico piano verticale**. Le foto si proiettano sul piano via **omografia** (istantaneo,
  niente ricostruzione 3D). Il rilievo (bovindo, rientranze) viene *appiattito*. Perfetto per
  prospetti dritti e preventivi di superficie.
- **Ricostruzione 3D (pesante, GPU):** Meshroom (MVS) o 2D Gaussian Splatting ricostruiscono
  il volume vero, incluso il bovindo, ma sono rumorose e vanno pulite.

**Strategia Acrobatica:** piano piatto per il 95% (il muro), e ricostruzione 3D **solo dove
serve davvero** (gli elementi sporgenti), guidata dall'utente — "**premodellazione**".

Principio chiave di sicurezza metrica: **l'AI / il 3D servono a *capire e regolarizzare*, mai
a *inventare* metri quadri** che il cliente paga. Le misure vengono sempre da dati (pose ARKit
+ nuvola), non da geometria allucinata.

---

## FASE 1 — Acquisizione (lo scatto)

### 1.1 App di cattura (iOS, stile RealityScan)
File: `ios/Acrobatica/Capture/ARFacadeCaptureManager.swift`, `ios/Acrobatica/Screens/CatturaARView.swift`.

- **ARKit sempre attivo** durante la cattura: fornisce, per ogni frame/foto, la **posa camera**
  (`camera_transform`, 4×4) e gli **intrinseci** (`camera_intrinsics`, 3×3), nel sistema mondo
  ARKit **allineato a gravità (Y = su)**.
- **Auto-capture su movimento:** scatto automatico quando ci si sposta ≥ ~25 cm **oppure** si
  ruota ≥ ~12° dall'ultimo scatto. Evita foto ridondanti e copre in modo uniforme.
- **Esposizione scelta (non solo bloccata):** slider EV (`setExposureTargetBias`) + tempo di
  posa rapido di default (`setExposureModeCustom(duration:iso:)`, `ShutterSpeed` 1/250…1/2000)
  per evitare mosso.
- **Guida di copertura** (CoverageStrip 1D) per non lasciare buchi sul fronte.
- **Riduzione calore:** `planeDetection = []`, risoluzione media (1920 px) — non max.

### 1.2 REGOLA D'ORO della ripresa (lezione appresa, critica)
La qualità del 3D dipende **al 90% da come ci si muove**:

- **CAMMINARE LATERALMENTE lungo il fronte** (traslazione orizzontale), NON ruotare sul posto.
  - ✅ Buono: 48 m di percorso lungo i 33 m di facciata → baseline ampia → MVS/2DGS puliti.
  - ❌ Cattivo: 215 foto da un punto solo ruotando (movimento 3.4 m verticale, ~0 orizzontale)
    → baseline debole → mesh rumorosa, profondità sbagliata. *(Successo davvero, sessione 1553:
    le camere si erano spostate solo 15–23 cm in orizzontale.)*
- **Sovrapposizione** ~70% tra foto consecutive.
- **Passo** ~0.5–1 m tra scatti; per il bovindo, **girargli intorno** (riprese da angolazioni
  diverse) così il cloud ha punti sulla sporgenza a varie profondità.
- **Distanza** costante dal muro quando possibile; evitare controluce forte.

### 1.3 Dati per foto (cosa si salva)
Ogni foto porta con sé nei metadati:
- `camera_transform` — 4×4 **column-major**, camera→mondo, convenzione ARKit/OpenGL
  (camera guarda **−Z**, +Y su, +X destra).
- `camera_intrinsics` — 3×3 **column-major**, riferiti a una risoluzione di riferimento
  (vanno **riscalati** alla risoluzione reale dell'immagine).
- `image_width`, `image_height`, `order_index` (indice progressivo, chiave di accoppiamento).

### 1.4 Upload robusto
File: `BackgroundUploader` (in `BackendAPIClient.swift`), `AcrobaticaApp.swift`.
- **Background URLSession** (`com.acrobatica.upload.bg`), upload file-based multipart, sopravvive
  a standby/crash (riprende al rilancio), coda persistente `pending_uploads.json`.
- "**Fine**" esce dalla pagina fotocamera → gli upload continuano in background.
- Concorrenza limitata + retry (`uploadPhotoRetrying`) per non perdere foto.

---

## FASE 2 — Nuvola di punti (quando serve e dove farla)

| Operazione a valle | Qualità nuvola richiesta | Dove |
|---|---|---|
| **Fit del piano del muro** (FASE 3) | bassa (RANSAC tollera il rumore) | **LOCALE, niente pod** |
| **Estrazione 3D del bovindo** (FASE 5) | alta (densa, pulita) | GPU: Meshroom o 2DGS |

### 2.A Nuvola LOCALE (CPU Mac, niente pod) — sufficiente per il piano
File: `backend/scripts/run_cloud_fast.py`.
- Triangolazione **pose-prior**: SIFT + matching con filtro coppie intelligente (finestra di
  vicini + baseline 0.15–max + angolo asse ottico), triangolazione con **pose ARKit fisse**.
- Output: `/tmp/cloud_fast_<sid>/cloud.ply` (es. 215 foto → ~727k punti, ~12 min CPU).
- ⚠️ **Rumorosa sugli elementi ripetitivi/sporgenti** (il bovindo "fa la patata"): va bene
  **solo** per fittare il piano dominante, NON per modellare il bovindo.
- ⚠️ **Salvare subito in cartella durevole** (`/tmp` viene svuotato da macOS):
  `~/Documents/acrobatica_mesh/sess_<sid>/locale/`.

### 2.B Nuvola DENSA (GPU pod) — per il bovindo / qualità
Due motori, entrambi in **scala metrica** dopo il rescale ARKit (vedi 2.C):

**Meshroom (MVS)** — `backend/scripts/run_meshroom_pipeline.sh`
- Pipeline: cameraInit → injectPoses (ARKit) → featureExtraction → imageMatching
  (**VocabularyTree**, NON Exhaustive: con 215 foto evita 23k coppie) → featureMatching →
  incrementalSfM (`--lockScenePreviouslyReconstructed 1 --lockAllIntrinsics 1`) → prepareDenseScene
  → depthMap (CUDA) → depthMapFilter → meshing → meshFiltering → meshDecimate → texturing.
- **Lezioni/accortezze:**
  - `export OMP_NUM_THREADS=16` + `--maxThreads 16` (il container vede 256 core host → senza
    limite: *"libgomp: Thread creation failed"*).
  - GPU **Ampere (A100, sm_80)** OK; evitare Blackwell (sm_120) con Meshroom 2023.3.
  - Tempi tipici (215 foto @1920, A100): featExtr 225s, featMatch 552s, SfM 87s, depthMap 321s,
    meshing 618s, texturing 49s → ~34 min. Colli di bottiglia legati al **numero di foto**, non
    ai pixel → per accorciare: **meno foto ben distribuite**, non meno risoluzione.

**2D Gaussian Splatting** — repo `hbb1/2d-gaussian-splatting`
- Input: dataset **COLMAP** generato dalle pose ARKit → `backend/scripts/arkit_to_colmap.py`.
- Setup pod (CUDA 12.8 / gcc 13): patchare gli header dei rasterizzatori CUDA con
  `#include <cstdint>` (errore `uint32_t/uintptr_t undefined`) e `#include <float.h>`
  (`FLT_MAX undefined`); installare con `pip install --break-system-packages --no-build-isolation`.
  Deps extra: `ninja plyfile opencv-python tqdm matplotlib mediapy trimesh open3d` (open3d:
  `--ignore-installed blinker` per il conflitto col pacchetto Debian).
- Training: `python train.py -s <data> -m <out> --iterations 30000 -r 2`. Estrazione mesh
  (TSDF): `python render.py -m <out> --iteration N --skip_test --depth_ratio 1.0`.
- Vantaggi attesi su facciate ripetitive: ottimizzazione fotometrica multi-vista (regge meglio
  del matching SIFT) + colore incluso. **Da validare** sui nostri dati.

### 2.C Convenzioni e RESCALE metrico (CRITICO)
- **Conversione posa ARKit → OpenCV/COLMAP/AliceVision** (world→camera):
  `FLIP = diag(1,−1,−1)`; `R_w2c = FLIP · R_c2w^T`; `t = −R_w2c · C` (C = centro camera).
  Rotazione salvata **column-major**. (File: `arkit_to_alicevision.py`, `arkit_to_colmap.py`.)
- **Intrinseci**: scalare `fx,fy,cx,cy` dalla risoluzione di riferimento a quella reale.
- ⚠️ **Bug di scala (gauge) risolto:** l'`incrementalSfM` NON fissa la gauge globale
  (scala+rotazione+traslazione) → l'output esce in **scala arbitraria** (es. 10.6× troppo
  piccolo). FIX: `backend/scripts/rescale_to_arkit.py` allinea i centri-camera SfM a quelli
  ARKit via **Umeyama** (residuo 0.0 mm → perfetto) e riporta mesh/cloud in **metri reali**.
  *Da agganciare sempre in coda alla pipeline.* La pipeline aggiornata lo fa già.
- **Verifica di sanità:** controllare l'estensione dei centri-camera ARKit grezzi
  (`camera_transform[12:15]`) — è la verità metrica. Se la ricostruzione non combacia → rescale.

---

## FASE 3 — Piano piatto metrico (il "prospetto dritto")

File di riferimento: `backend/scripts/run_flat_facade_ortho_from_arkit.py`,
`backend/app/services/orthorectify_service.py` (`WallPlane`, `fit_plane_from_points`).

### 3.1 Fit del piano (RANSAC)
- RANSAC sul cloud (anche locale rumoroso): trova il **piano dominante = muro principale**.
  I punti del bovindo e il rumore sono outlier → scartati.
- Soglia inlier ~3–5 cm (in scala metrica reale).

### 3.2 Base del piano — `WallPlane`
- `normal` = normale del piano (direzione di vista del muro).
- `up` = **gravità mondo proiettata sul piano** (il verticale resta verticale).
- `right` = `normal × up` (orizzontale sul muro).
- `u_min..u_max`, `v_min..v_max` = estensione in **metri** (dai punti inlier) → output metrico.

### 3.3 Ortofoto (proiezione delle foto sul piano)
- Griglia regolare sul piano a `ppm` **pixel/metro**: ogni pixel di output =
  `P_world = point + u·right + v·up` (un punto **sul piano piatto**).
- Per ogni foto: proiezione del punto-griglia nell'immagine con la posa ARKit
  (`rel = P_world − cam`, attraverso gli intrinseci) e campionamento `cv2.remap`.
- **Best-view per pixel** (vista più frontale/vicina) → composito; blend multi-band per togliere
  le giunzioni (lezione: `strip_composite_service` / MultiBandBlender).
- **Velocità:** piano e immagine sono entrambi piatti → la relazione è una **omografia 3×3**:
  proiettare 1 foto = `warpPerspective` (millisecondi). Il composito fuso delle N foto =
  **secondi** (batch leggero). **Nessuna ricostruzione 3D** ⇒ può essere reso **interattivo/live**.

### 3.4 Variante 2D pura (alternativa, parcheggiata)
File: `backend/app/services/rectify_facade.py` — 4 tap sugli angoli del muro
(TL,TR,BR,BL) → `cv2.getPerspectiveTransform` → warp a rettangolo. Niente ARKit/3D. Scala vera
da 2 tap + distanza nota. *Robusta ma aspect-ratio euristico; usare come fallback.*

---

## FASE 4 — Selezione utente (sulla "tela" del prospetto piatto)

- L'utente vede il **prospetto piatto metrico**; il bovindo appare *spalmato* (è proiettato come
  se fosse sul piano). Serve solo come tela per **indicare dove** sono gli elementi 3D.
- L'utente seleziona: il **contorno** del bovindo (box/poligono) oppure le **linee geometriche**
  (spigoli verticali, davanzali, cornici).
- La selezione **può essere grossolana**: la precisione finale viene dal fit sul cloud, non dai
  pixel spalmati.

---

## FASE 5 — Premodellazione (estrazione 3D guidata dal cloud)

Idea: la selezione 2D sull'ortofoto **definisce un volume 3D**.

### 5.1 Back-projection della selezione
- Ogni pixel selezionato `(u,v)` → punto sul piano `P0 = point + u·right + v·up`.
- L'elemento sporgente sta lungo la **normale** a partire da `P0` → la selezione definisce un
  **prisma 3D** perpendicolare al piano: `{ P0 + t·normal : t ∈ [0, t_max] }`.

### 5.2 Query sul cloud (denso!)
- Si prendono i **punti del cloud denso** la cui proiezione su `(right, up)` cade nella selezione.
- Si separano per **profondità** `t = (P − point)·normal`: muro `t ≈ 0`, bovindo `t > 0`.
- (Qui serve la nuvola **densa** — FASE 2.B — perché quella locale è troppo debole sulla sporgenza.)

### 5.3 Fit di primitive (RANSAC)
- Sui soli punti del bovindo: **RANSAC multi-piano** → le facce vere della baia
  (es. fronte + 2 fianchi angolati). Bovindo **curvo** → N facce o settore di cilindro.
- Le linee disegnate dall'utente si **agganciano agli spigoli reali** (intersezioni dei piani
  fittati) — non ai pixel.

### 5.4 Modello pulito
- Composizione: **muro = piano piatto** + **bovindo = primitive parametriche** snappate al piano
  al bordo. Niente "patata": geometria netta, in **scala metrica**.
- Output: prospetto dritto + volume del bovindo modellato → utile per preventivi *e* per resa 3D.

---

## FASE 6 — Editing live on-device (iPhone/iPad) — *roadmap*

Obiettivo: **modificare la geometria e vedere la texture ri-proiettarsi in tempo reale**.

### 6.1 Tecnica
- **Projective texture mapping** in **Metal** (RealityKit/SceneKit): ogni foto è un "proiettore"
  con la sua matrice camera; uno shader per-fragment campiona la foto sorgente. Editando la
  geometria, lo shader **ri-campiona al frame successivo** → la texture si riadatta a 60 fps.

### 6.2 Dettagli ingegneristici (non bloccanti)
1. **Quante foto live:** non campionare tutte le 215 per pixel. Per superficie si scelgono le
   **2–3 foto migliori** (più frontali/vicine). Il **blend fotorealistico finale** si **"cuoce"
   una volta** alla conferma (secondi), non a ogni frame.
2. **Occlusioni:** serve un **depth-test per proiettore** per non spalmare la foto del muro sulla
   faccia del bovindo (standard, un po' di shader in più). Sul piano singolo non serve.
3. **Performance:** A-series/M-series gestiscono poche sorgenti a 60 fps senza problemi.

### 6.3 Componenti da costruire (nuovo lavoro iOS)
- Shader Metal di projective texturing (uniform: foto + matrici camera + selezione best-view).
- UI di editing (gizmo: sposta piano, estrudi/ruota facce del bovindo).
- Pipeline di **bake** finale (composito multi-band → texture atlas) lato device o backend.

---

## Appendice A — Inventario file/script

| Scopo | File |
|---|---|
| Cattura iOS | `ios/Acrobatica/Capture/ARFacadeCaptureManager.swift`, `Screens/CatturaARView.swift` |
| Upload robusto | `BackgroundUploader` in `ios/Acrobatica/Networking/BackendAPIClient.swift` |
| Nuvola locale (pose-prior) | `backend/scripts/run_cloud_fast.py` |
| Pose ARKit → AliceVision | `backend/scripts/arkit_to_alicevision.py` |
| Pose ARKit → COLMAP (2DGS) | `backend/scripts/arkit_to_colmap.py` |
| Pipeline Meshroom (metrica) | `backend/scripts/run_meshroom_pipeline.sh` |
| Rescale metrico (Umeyama) | `backend/scripts/rescale_to_arkit.py` |
| Ortofoto piano piatto | `backend/scripts/run_flat_facade_ortho_from_arkit.py` |
| WallPlane / fit piano | `backend/app/services/orthorectify_service.py` |
| Rettifica 2D (4 tap) | `backend/app/services/rectify_facade.py` |
| Compositing / blend | `backend/app/services/strip_composite_service.py` |
| **OC locale: mesh+pose (stessa sessione)** | `octool_nobbox.swift` (`ignoreBoundingBox=true`) |
| **OC: estrazione sole pose** | `octool_poses.swift` |
| **OC: USDZ → OBJ (ModelIO)** | `usdz2obj.swift` |
| **OC: render mesh da posa nativa** | `scn_pose.swift` (verifica allineamento via bordi) |
| **Nuvola di sessione (per ICP di controllo)** | `build_session_cloud_5563.py` |
| **ICP di controllo (filtro+scala fissa)** | `align_mesh_icp.py` |

> Script OC locali in `~/Documents/acrobatica_mesh/sess_<sid>/` e `/tmp/*.swift`
> (⚠️ `/tmp` viene svuotato da macOS: tenere copia durevole in `~/Documents/...`).

## Appendice B — Errori noti e fix (memoria operativa)

**Object Capture (v2.0):**
- **Frame Model↔Session "irrisolvibile"** → in realtà risolto eseguendo `.modelFile` + `.poses`
  nella **stessa sessione** con `ignoreBoundingBox=true`; proiezione **0 px** di residuo.
- **Sembrava disallineato** → due *miei* difetti di visualizzazione: (a) spray di punti **senza
  occlusione**; (b) render **senza principal point** (shift di ~42 px). Tolti → bordi coincidono.
- **ICP `with_scaling` collassa** la mesh su nuvola con outlier (scala 0.13, "fitness 1.0" falso)
  → filtrare outlier + **scala fissa** (ICP rigido). Con OC nativo l'ICP **non serve**.
- **Open3D 0.19 non legge l'OBJ di OC** (ASSIMP si blocca sulla riga `o`/`g`) → parsare `v`/`f`
  a mano e costruire la mesh dagli array.
- **Cartella input "sporca"** (campioni `s0..s4` oltre alle foto numerate) → OC genera **pose in
  più** non allineate al conteggio foto. Usare una cartella con **solo** le foto numerate.
- **Foto in portrait salvate "sdraiate"** (sensore landscape fisso): le pose/intrinseci OC si
  riferiscono ai pixel **così come sono su disco**. Per le metriche **scattare in orizzontale**.

**Meshroom / 2DGS / generale:**

- **Scala arbitraria post-SfM** → `rescale_to_arkit.py` (Umeyama su centri camera).
- **`/tmp` svuotato da macOS** → salvare sempre in `~/Documents/acrobatica_mesh/...`.
- **`libgomp: Thread creation failed`** (256 core host) → `OMP_NUM_THREADS=16` + `--maxThreads 16`.
- **2DGS build su CUDA 12.8/gcc 13** → patch `#include <cstdint>` e `#include <float.h>`;
  `pip install --break-system-packages --no-build-isolation`; open3d con `--ignore-installed blinker`.
- **SSH su pod già avviato** → la chiave non si propaga; aggiungerla a mano via web terminal
  (`>> ~/.ssh/authorized_keys`) oppure riavviare il pod.
- **Nuvola pose-prior locale** → inutilizzabile sugli elementi ripetitivi/sporgenti (rumore 85%):
  usarla solo per il fit del piano, mai per il bovindo.
- **Matching Exhaustive con molte foto** → esplode; usare **VocabularyTree**.

## Appendice C — Convenzioni numeriche

- ARKit world: **Y = su** (gravità). `camera_transform` 4×4 **column-major**, camera→mondo,
  camera guarda **−Z**.
- OpenCV/COLMAP/AliceVision: world→camera, camera guarda **+Z**, +Y giù. `FLIP = diag(1,−1,−1)`.
- Intrinseci: scalare alla risoluzione reale dell'immagine.
- Scala: **sempre verificare** contro i centri-camera ARKit grezzi; applicare Umeyama se serve.

---

*Fine documento — **v2.0 (2026-06-05)**. Novità principale: **pipeline Object Capture locale
con allineamento nativo pixel-accurato** (vedi sezione ⭐ SVOLTA) — risolve il problema
Model↔Session e abilita texture metrica nitida senza GPU cloud.*

*Prossimi step: (1) generare l'**ortofoto del fronte ri-proiettata** dalle pose OC native
(FASE 3 con il nuovo allineamento); (2) integrare la pipeline OC locale nel flusso di prodotto;
(3) editor live on-device (FASE 6). Limite residuo noto: zone **non riprese** (tetto/retro) →
guida di cattura per copertura completa.*
