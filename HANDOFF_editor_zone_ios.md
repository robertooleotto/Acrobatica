# HANDOFF — Editor marcatura zone iOS (nuova discussione)

## Cosa esiste già (creato il 2026-06-12, COMPILA: `BUILD SUCCEEDED` su simulatore)
- `ios/Acrobatica/Screens/MarcaturaFacciataView.swift` — schermata editor completa:
  canvas con ortofoto+zone, toolbar strumenti in basso (seleziona/poligono/rettangolo/mano),
  pannello proprietà, outliner zone (sheet dal basso), HUD con coordinate in metri e
  totali m² per tipo, undo/redo a snapshot (50 passi), share sheet del JSON,
  `MarcaturaFacciataCaricamentoView` (loader da URL), `#Preview` con facciata demo procedurale.
- `ios/Acrobatica/Models/ZonaFacciata.swift` — `TipoZona` (esclusa/da_rifare/misurabile/nota),
  `ZonaFacciata`, documento `MarcaturaFacciata` Codable; shoelace per aree, perimetri,
  point-in-polygon. SCHEMA JSON CONCORDATO con la pipeline Python (NON cambiarlo):
  `{"versione":1,"ppm":110,"larghezza_px":...,"altezza_px":...,"zone":[{"nome","tipo","visibile","colore","punti_px":[[x,y]],"area_m2","perimetro_m"}]}`
- `ios/Acrobatica/DesignSystem/Components/EditorGestureView.swift` — gesti UIKit
  (pinch zoom ancorato al punto, pan 2 dita, drag maniglie, double-tap fit; target iOS 16).
- Navigazione: bottone "Segna zone (escluse / da rifare)" in `RisultatoPanoramaView.swift`
  → fullScreenCover, scarica `stitchedUrl`, ppm = 1/metersPerPixel (fallback 110).
- Tema: "workstation" scura stile Blender (#232323/#2d2d2d, accento #e87d0d),
  volutamente distinta dal design chiaro FacciataPro ma usa Theme.Typo e BrandButton.
- Persistenza: autosave in `Documents/marcature_facciata/<nome>.json` per sessionId.

## Fatti il 2026-06-12 (sessione successiva all'handoff, BUILD SUCCEEDED + 36 test backend verdi)
1. ~~Upload del JSON al backend~~ FATTO: `PUT/GET /facade-sessions/{id}/zone-markup`
   in `backend/app/routers/facade_sessions.py`; logica pura in
   `backend/app/services/zone_markup.py` (validazione, RICALCOLO server-side di
   aree/lunghezze da punti_px+ppm, totali per tipo solo zone visibili; test in
   `backend/tests/test_zone_markup.py`). JSON salvato su storage come
   `out/zone_markup.json` + totali in `result.zone_markup`. Lato iOS:
   `BackendAPIClient.uploadZoneMarkup`, bottone cloud nella barra superiore
   dell'editor (stati: in corso/ok/errore con alert e riprova), `sessionId`
   passato da `RisultatoPanoramaView` → loader → editor.
3. ~~Tipo zona "lineare"~~ FATTO: `TipoZona.lineare` (viola #C66BD6, polilinea
   APERTA, area_m2=0, perimetro_m=lunghezza in m). Disegno con alone+tratto,
   etichetta a metà percorso; col tool rettangolo il drag crea un segmento
   dritto A→B; "Termina linea" (min 2 punti) al posto di "Chiudi poligono";
   hit-test per vicinanza al segmento (tolleranza scalata con lo zoom); HUD e
   outliner mostrano i m lineari. Il backend accetta tipo="lineare".
5a. ~~Zone nascoste nei totali HUD~~ FATTO: `areaTotale`/`lunghezzaTotale`
   filtrano `visibile`; idem i totali server-side.

2. ~~Pre-marcatura automatica dal fuori-piano~~ FATTO (sopra la nuvola di
   `GET /planes`, non sulla mappa δ v18): `GET /facade-sessions/{id}/zone-proposals`
   (`backend/app/services/zone_proposals.py` + test) — δ = distanza dal piano
   principale, punti con δ>0.15 m → occupancy grid 20 cm → contorni cv2 →
   poligoni "esclusa" in px ortofoto (convenzione v22: x=(u−u_min)·ppm,
   y=(v_max−v)·ppm). `/planes` ora salva la nuvola in `out/cloud.npz`
   (riusata senza ritriangolare). iOS: all'apertura dell'editor (sessione
   presente, zero zone) scarica le proposte, le riscala sull'immagine mostrata
   SOLO se le proporzioni combaciano (±3%, altrimenti le ignora con banner),
   le aggiunge come "Aggetto N (auto)" annullabili con undo + banner HUD.
   NOTA: finché l'editor mostra lo stitched (non l'ortofoto del piano), il
   check proporzioni scarterà quasi sempre le proposte — il pezzo mancante è
   servire l'ortofoto v22 dal backend e aprirla nell'editor.

## Lavori rimasti (in ordine di valore)
4. **Test reale su device/simulatore** con un'ortofoto vera (es.
   `/Users/liscio/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/exports/facade_clean/tex_0_true60_v22.png`,
   2268×1936 @ 110 px/m) e rifiniture UX che emergono.
5b. Self-intersection check sui poligoni.
6. Rinomina zona: oggi salva su submit ma non passa dall'undo (scelta deliberata, rivedere se serve).
7. Deploy backend su Railway (gli endpoint zone-markup sono solo in locale finché non si pusha).

## Contesto prodotto (non toccare in questa discussione, solo da sapere)
- La pipeline ortofoto di riferimento è la "v22" (vera ortofoto + center-first +
  shear bundle); il porting backend è un filone separato.
- Prototipo desktop equivalente: `exports/facade_clean/editor_facciata.html`
  (se esiste; un agente lo stava costruendo) — solo come riferimento funzionale.
- Esiste anche un set di visori web diagnostici (`view_projection.html` ecc.) in
  `exports/facade_clean/` — non c'entrano con l'app.
