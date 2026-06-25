# HANDOFF — Editor 3D mesh facciata iOS

## Visione (decisa con l'utente il 2026-06-14)
La pagina 3D carica la **mesh densa di Object Capture**, la fa **ripulire**
all'operatore (togliere punti sparsi e porzioni di edificio non utili) con
**taglio distruttivo on-device**, e da lì si **estraggono facciate/elementi →
piani puliti e squadrati** su cui poi avviene la **proiezione delle mappe**
(texture). Rientranze/sporgenze vengono appiattite sul piano o trattate dopo.

Catena: cattura foto (già esiste) → Object Capture **sul Mac** → mesh caricata
sul backend → **iPad scarica e modifica** → mesh pulita + piani → ortofoto →
editor 2D zone (escluse/da rifare/m²) resta a valle per il preventivo.

## Decisioni architetturali
- **Sorgente mesh**: Mac genera OC → backend la conserva/serve → iPad scarica.
  NON Object Capture in-app (resterebbe iOS 17+/LiDAR): manteniamo iOS 16.
- **Editing**: distruttivo on-device (seleziona regioni → cancella triangoli+punti
  → esporta mesh pulita).
- **Rapporto col 2D**: il 3D è a monte (estrae piani puliti per la proiezione);
  l'editor 2D zone resta lo strumento del preventivo, a valle.
- **Tech rendering iOS**: **SceneKit** (`SCNView`), non RealityKit — carica
  OBJ/USDZ nativamente (iOS 16), orbit camera, accesso ai buffer
  vertici/indici per il taglio per-triangolo, hit-testing.
- **Formato mesh in transito**: **OBJ** (+ MTL/PNG texture) — il Mac ha già il
  converter `backend/photogrammetry/objectcapture/usdz2obj.swift`; OBJ è
  testuale, facile da ri-esportare dopo il taglio. Ottimizzare a binario (PLY)
  solo se la dimensione/parse su device diventa un problema.

## Fasi (in ordine)
1. **Fondamenta** (IN CORSO 2026-06-14): backend I/O mesh
   (`PUT/GET /facade-sessions/{id}/mesh`) + visore 3D iOS `EditorMesh3DView`
   (SceneKit, orbit/pan/zoom, auto-frame sul bounding box) con mesh di test
   procedurale + loader OBJ/USDZ da URL. Build verde.
2. **Selezione / creazione faccia per punti** (IN CORSO 2026-06-14):
   toolbar in `EditorMesh3DView` con strumenti **Naviga** (orbit) e **Punti**.
   In modalità Punti: tap sulla mesh → hit-test SceneKit → vertice (sfera +
   polilinea) in world space; barra contestuale Indietro/Annulla/Crea faccia
   (≥3 punti) → poligono semitrasparente arancio + contorno (porta la stessa
   UX del tool poligono dell'editor 2D nel 3D). Conteggio facce nell'HUD.
   TODO: snap/edit dei vertici, fit del piano dai punti (least-squares) e
   squadratura, uso della faccia come maschera per il taglio (Fase 3).
   Manca ancora la selezione di REGIONI per il taglio (box/lazo/pennello).
3. **Taglio distruttivo**: cancella i triangoli/vertici selezionati dai buffer
   SCNGeometry, undo/redo, ricostruzione normali; esporta OBJ pulito → upload.
4. **Denoise**: rimozione automatica outlier (componenti connesse piccole,
   statistical outlier removal) come azione one-tap.
5. **Estrazione piani**: dalla mesh pulita stima i piani facciata (RANSAC; il
   backend ha già `facade_planes.detect_planes`), squadra e orienta; output i
   piani su cui proiettare le mappe.
6. **Proiezione mappe → ortofoto**: render della texture sul piano squadrato
   (probabile filone backend) → alimenta l'editor 2D zone.

## Stato fondamenta (Fase 1)
- Backend: `PUT /facade-sessions/{id}/mesh` (upload da Mac, multipart obj+texture),
  `GET /facade-sessions/{id}/mesh` (URL firmati + info). File in
  `out/mesh/`. Vedi `backend/app/routers/facade_sessions.py` + test.
- iOS: `ios/Acrobatica/Screens/EditorMesh3DView.swift` — SceneKit container,
  orbit camera, auto-frame, HUD info; mesh demo procedurale (muro + balcone
  sporgente + triangoli sparsi da pulire) per provare al simulatore senza la
  mesh vera; loader async da URL (OBJ/USDZ via `SCNScene(url:)`).
- Client: `BackendAPIClient.fetchMeshURL` / `uploadMesh`.

## Spec proxy-editor (AUTORITATIVA — utente 2026-06-15)
È un **editor di correzione proxy**, NON un modellatore completo. Strumenti:

1. **Box di lavoro**: gizmo scala/sposta/ruota il volume · Applica crop (elimina
   poligoni fuori dal box) · Inverti crop (elimina dentro) · Reset box.
2. **Selezione/Rimozione**: lazo · rettangolo · pennello selezione · Cancella
   selezione (poligoni volanti/rumore) · Ripristina (undo).
3. **Pennellate per facce**: pennelli colorati (1 colore = 1 faccia/piano) ·
   scarabocchi stesso colore → stessa faccia · nuovo colore/faccia · rinomina
   (facciata, spalletta, davanzale, torretta…) · genera piani da pennellate.
4. **Piano livello zero**: strumento 3 punti → piano medio principale · da quel
   piano offset/rientri/rilievi · ricalcola piani da livello zero.
5. **Editing facce proxy**: seleziona · unisci · dividi · escludi · cambia tipo
   (facciata/spalletta/orizzontale/torretta/bordo/scarto) · priorità layer (bake).
6. **Editing geometrico fine**: modalità vertice/edge/faccia · muovi · snap a
   (piano base, bordo, vertice, asse V/H, griglia) · nudge fine (frecce/step).
7. **Contorni e bordi**: seleziona edge · marca spigolo · snap edge-edge ·
   allinea V/H · estendi/taglia faccia fino a edge.
8. **Validazione**: mostra mesh OC texture / proxy colorati / solo facce
   accettate / scarti · overlay errore distanza mesh-piano · anteprima camera
   projection su faccia.
9. **Salvataggio**: `proxy_overrides.json` · `multipiano_proxy.json` · stati
   (automatico / corretto manualmente / bake-ready).

ORDINE: 1 box+crop → 2 lazo/rett/pennello → 3 pennelli colorati facce → 4
3-punti piano base → 5 unisci/dividi/escludi → 6 snap/edit vertici-edge (ultimo).

STATO (2026-06-18):
- §1 box+crop FATTO: box ORIENTATO (PCA, non ruota la mesh) + maniglie grandi
  (sfere bianche/anello) trascinabili sulle 6 facce · Allinea · Reset · Ritaglia
  · Inverti. Crop su box orientato (frame locale). `EditableMesh.orientedBox()`
  (Jacobi eigen 3×3).
- §2 FATTO: selezione Lazo + Rettangolo + Pennello (proiezione centroidi
  cache-ata a inizio gesto, camera ferma) · Cancella · Ripristina (undo/redo) ·
  ops Tutto/Niente/Inverti/Frammenti(isole piccole)/Espandi/Restringi.
- §3 FATTO: pennelli colorati = facce proxy. `FacciaProxy` (id, nome, colore
  palette, tipo TipoFaccia, Set triangoli, piano fittato) in EditableMesh.swift.
  Strumento "Facce": pennello assegna triangoli alla faccia attiva (li toglie
  dalle altre) · Nuova faccia · rinomina · menu Tipo
  (facciata/spalletta/davanzale/orizzontale/torretta/bordo/scarto) · elimina ·
  Genera piani (PCA `mesh.fitPiano`). Overlay colorato per faccia. `elimina`
  ora ritorna il remap vecchio→nuovo indice → `rimappaFacce` mantiene le facce
  coerenti dopo i tagli; undo/redo snapshottano anche le facce.
- §4 FATTO: piano livello-zero. Strumento "Piano base": tocchi 3+ punti sul
  muro → `calcolaPianoBase()` fit PCA → origine+normale+assi, quad visualizzato.
  "Allinea box" orienta il box di lavoro sul piano base. (Lo strumento "Punti"
  fan-face è stato riconvertito a questo; rimosso numFacce.)
- §5 PARZIALE: tipo, rinomina, elimina, priorità layer (stepper) fatti.
  Mancano unisci/dividi facce (escludi = tipo "scarto").
- §9 FATTO + VERIFICATO: export `<nome>_proxy_overrides.json` (mesh info, stato,
  piano_base, facce con colore hex/tipo/priorità/triangoli/piano) e
  `<nome>_multipiano_proxy.json` (solo piani per bake) via share sheet
  (bottone in alto). `StatoProxy` automatico/corretto/bake-ready.
- §8 FATTO (viste): menu occhio in alto → toggle "Proxy colorati" + viste
  Tutto/Solo accettate/Solo scarti/Solo proxy (trasparenza mesh + filtro
  overlay per tipo). Errore di planarità per faccia (RMS triangoli↔piano,
  `mesh.rmsDalPiano`) mostrato nella riga faccia, rosso se > soglia (1% lato).
- §5 COMPLETO: + unisci facce (menu "Unisci ⟨faccia⟩" assorbe i triangoli e
  rimuove la sorgente). Split = implicito (ripennelli su faccia nuova);
  escludi = tipo "scarto".
- §6/§7 FATTI come RIFINITURA PIANI (scelta di merito: su mesh 157k tri
  l'editing dei singoli vertici non serve a un editor proxy). Per faccia con
  piano: Squadra (snap normale all'asse base/mondo più vicino), Verticale
  (normale ⟂ up → faccia verticale), Orizzontale (normale = up), Offset ±
  (rientro/rilievo lungo la normale, step ‰ del lato). Piani fittati
  visualizzati come quad colorati (toggle "Piani fittati" nel menu occhio).
  `assicuraPiani()` in export fitta solo i mancanti → le rifiniture manuali
  sopravvivono (verificato: dopo Squadra la normale resta [0,0,-1] nel JSON).
- TUTTE LE 9 SEZIONI COPERTE. Restano fuori, per scelta/dipendenze:
  vista "mesh OC texture" (mesh ora grigia, texture scartata all'import) e
  anteprima camera-projection (§8, filone a valle); edge editing letterale §7
  e vertex-drag letterale §6 (non pertinenti a un proxy editor su mesh densa).
- CURSORE 3D (2026-06-18): in modalità Naviga il tap posa un mirino
  (sfera arancio + croce bianca) sulla mesh via hit-test; usa
  `SCNHitTestResult.faceIndex` (= indice triangolo nel nostro buffer) per dire
  nell'HUD su quale faccia proxy si trova (nome · tipo · n.tri).
  `posizionaCursore`/`nascondiCursore` in Mesh3DModel.

- VIEWCUBE (2026-06-18): gizmo navigazione in alto a destra (stile 3ds Max):
  cubetto SCNView che rispecchia l'orientamento camera (cube.simdOrientation =
  cameraQuat.inverse, letto via SCNSceneRendererDelegate.updateAtTime),
  anello tratteggiato, bottoni ⟳(auto-rotazione) F/A/◳(iso). Tap su una faccia →
  snap a quella vista (localNormal → asse). Snap = nuovo nodo camera assegnato
  a v.pointOfView (impostare il transform del pov esistente NON regge: il
  defaultCameraController lo sovrascrive — fix verificato). Auto-rotazione =
  SCNAction repeatForever su contentNode con pivot al centro, reset all'off.
  NB: Fronte/Alto/Iso usano gli assi del PIANO BASE se impostato, altrimenti
  assi mondo (su mesh OC arbitraria le viste mondo possono risultare di taglio).

- §1 RIFINITO (2026-06-18): (a) maniglie ora cubetti/grip piccoli (lato ~1.8%
  del box) invece di sfere enormi; (b) CLIP LIVE via shader modifier `.surface`
  sul materiale mesh (`clipModifier`): in modalità Box scarta i frammenti fuori
  dal box in tempo reale (params clipLo/clipHi/clipInv/clipOn via `aggiornaClip`,
  chiamato in ricostruisciBox/renderMesh/strumento didSet) → stringendo il box
  la mesh fuori sparisce; (c) `allineaBox` usa il PIANO BASE se impostato
  (allineamento esatto alla facciata), altrimenti RANSAC piano dominante.
- §1 ALLINEAMENTO RIFATTO: la PCA grezza dava box storto (normale falsata da
  bordi/terreno). `allineaBox` (senza piano base) ora usa
  `mesh.orientedBoxRANSAC()`: RANSAC del piano dominante (facciata) → assi dalla
  PCA dei SOLI inlier (`pcaFrame`) → bounds su tutti i vertici. Fallback
  `orientedBox()` (PCA) se RANSAC fallisce.
  IMPORTANTE: la normale viene dal RANSAC/PCA inlier, ma verticale/orizzontale
  del box sono ANCORATE al "su" del mondo (worldUp proiettato sul piano): la PCA
  in-plane sceglieva la diagonale della varianza → box ruotato attorno alla
  normale → tagli storti. Con worldUp i bordi restano verticali/orizzontali
  (la mesh OC sta dritta nel mondo). Verificato.

- §2 PENNELLO RIFINITO (2026-06-18): dimensione regolabile (`raggioPennello`
  @Published, slider 12–110 px) + VINCOLO NORMALI opzionale con tolleranza
  (`vincolaNormali`, `tolleranzaNormaleGradi` 5–80°): a inizio pennellata
  cattura la normale del triangolo sotto il dito (`catturaNormaleRif` via
  hit-test faceIndex) e include solo i triangoli con |n·ref| ≥ cos(toll)
  (`passaNormale`). Vale per pennello Selezione E pennello Facce.
  `controlliPennello` mostrato in barraSelezione (modo pennello) e barraFacce.
  `mesh.normale(i)` = normale per triangolo.
- §3 FACCE AUTO (2026-06-18): "Riconosci facce" segmenta TUTTA la mesh in
  piani (`mesh.segmentaPiani` = RANSAC sequenziale per prossimità+normale, voto
  su sottocampione ~5000 per velocità in debug, materializza inlier sul pool
  pieno). `model.riconosciFacce()` async (off-main, spinner `segmentando`) →
  crea N FacciaProxy colorate + piani fittati + tipo auto (normale ~verticale →
  orizzontale). Verificato: 10 facce su mesh 6cdc. L'utente ritocca con
  pennello/unisci/elimina. Scelta utente: auto su tutta la mesh.
- §3 BRUSH-SEEDED (2026-06-18, l'utente vuole QUESTO, non auto su tutta mesh):
  flusso "nuova faccia → pennella un segno → Espandi al piano → Punto zero".
  * `espandiAlPiano()`: fit piano del pennellato → `mesh.crescePianare` cresce
    per APPARTENENZA AL PIANO (non topologia: la mesh OC ha vertici splittati,
    il flood-fill topologico cresce 1→6; per piano cresce 1→1215 ✓). Prende i
    triangoli coplanari (tolDist ~0.8% lato) + allineati (tolGradi). Finestre
    rientranti/balconi sporgenti = offset diverso → esclusi automaticamente.
  * `impostaPuntoZero(world)` (toggle "Punto zero" → tap sul muro vero):
    ancora il piano della faccia a passare per quel punto, mantenendo
    l'orientamento. Così finestre/balconi restano fuori e si appiattiscono sul
    muro reale (non su una finestra/balcone). Tap gestito in handleTap (.facce
    + attendePuntoZero).
  * "Riconosci facce" ORA È BRUSH-SEEDED (richiesta utente 2026-06-18): NON
    segmenta tutta la mesh; per ogni faccia che ha un segno pennellato cresce al
    suo piano (`crescePianare`) + fitta. Senza segni → niente (guard). Off-main,
    spinner. Verificato: 2 segni → 2 piani (fianco 1215, facciata principale 4222).
    `segmentaPiani` (auto tutta mesh) resta nel codice ma NON è più usata.
  * FIT RANSAC (2026-06-18, "come nel backend"): il piano del segno NON si fitta
    più con PCA pura (storto se il segno prende finestre/balconi) ma con
    `mesh.fitPianoRANSAC` (RANSAC del piano dominante + PCA sugli inlier).
    Usato in espandiAlPiano E riconosciFacce, sia sul seme sia sul cresciuto.
    Verificato: 2 segni cluster → Faccia1 11.353 (facciata principale) +
    Faccia2 2437, piani robusti (con PCA pura prendeva molto meno/storto).
- §3 ANCORA DA FARE: maniglie sul QUAD del piano (4 angoli) per allargare
  l'edge fino all'angolo reale della facciata (parti dal quad rettangolare).

- CRASH REPORTER (2026-06-19): `ios/Acrobatica/CrashReporter.swift`. Cattura
  eccezioni Obj-C (NSSetUncaughtExceptionHandler) + segnali POSIX (SIGSEGV/
  SIGABRT/SIGILL/SIGTRAP/SIGBUS/SIGFPE) → scrive `Documents/last_crash.txt`
  (segnale + stack). `CrashReporter.install()` in AcrobaticaApp.init;
  `.crashBanner()` mostra il report al riavvio (sheet con Condividi).
  Leggibile anche dal container sim: `$(simctl get_app_container … data)/Documents/last_crash.txt`.
  Hardening: `EditableMesh.normale(_:)` ora bounds-safe (faceIndex hit-test).

Tutto NATIVO Apple: Swift/SwiftUI + SceneKit + ARKit + ModelIO + simd + UIKit.
Nessun framework web/cross-platform. iOS 16+.
Le vecchie "Fasi" sotto sono superate da questa spec.

## Mesh reale precaricata (DEV — da rimuovere prima del rilascio)
- `ios/Acrobatica/Resources/facciata_demo.obj` (~14 MB) = copia geometry-only
  (mtllib/usemtl rimossi) di `~/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/model_nobbox.obj`
  (78.733 vertici / 157.071 triangoli, l'intera facciata OC NON rifilata).
- `EditorMesh3DView` la carica dal bundle quando NON c'è una sessione (path
  demo), così la si prova al simulatore con una facciata vera. Reso verificato
  il 2026-06-14 (grigio, dettaglio finestre/cornici + bordi sparsi da pulire).
- È un asset di test: toglierlo dal target/bundle prima della distribuzione
  (la mesh vera arriverà via backend, vedi Fase 1). Materiale grigio applicato
  via `applicaMateriale(a:)` perché l'OBJ non porta materiale (default bianco
  → sovraesposto); `autoenablesDefaultLighting=false`, solo directional+ambient.

## Note/contesto
- La mesh OC è in un **sistema di coordinate arbitrario** (≠ ARKit): l'editor
  lavora nello spazio mesh, auto-frame sul bounding box. La messa in scala
  metrica/allineamento è un problema separato (vedi memory
  `ortho-arkit-native-poses`, bridge Umeyama).
- Mesh OC reali sono dense (10⁵–10⁶ triangoli): attenzione a parse OBJ e
  memoria su device; valutare decimazione lato Mac/backend prima dell'upload.
- Per provare senza device: la mesh demo procedurale è indicizzata
  (vertici+facce reali), così la stessa pipeline regge il taglio distruttivo.
