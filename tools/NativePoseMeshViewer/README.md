# NativePoseMeshViewer

Visore macOS (SwiftUI + SceneKit) per ispezionare la proiezione delle foto della
sessione Object Capture sui piani BCS della facciata, usando le **pose OC native**
(frame OC). Serve a mettere a punto e diagnosticare il mosaico foto→piani prima di
portarlo nella pipeline di prodotto.

## Build / run

```sh
swift build -c release
cp .build/release/NativePoseMeshViewer .build/debug/NativePoseMeshViewer.app/Contents/MacOS/NativePoseMeshViewer
open .build/debug/NativePoseMeshViewer.app
```

(Il bundle `.app` va generato una volta con `swift build`; poi si aggiorna copiando
il binario. La cartella `.build/` è ignorata da git.)

## Dati usati (percorsi assoluti nel sorgente)

- mesh OC: `~/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/model_nobbox.obj`
- pose OC: `.../oc_poses_nobbox.json`
- foto: `backend/data/fixtures/6cdcb8ff/photos` (327, 1920×1440)
- piani BCS (frame OC): `exports/bcs_planes_handoff_20260701/bcs_standard_oc.obj`

## Pipeline del mosaico (`buildMosaic`)

Ogni piano BCS è tessellato in celle (~5,5 cm). Per ogni cella competono TUTTE le foto
(niente pre-filtro globale). Punteggio per cella:

```
2·assialitàH + 0,4·frontalità + 0,8·centralità + 0,35·vicinanza
```

- **assialitàH** = 1/(1+2·tanθ_h), θ_h = obliquità orizzontale del raggio rispetto al
  piano. È il termine dominante: cura la parallasse delle finestre incassate (che
  mostravano una sola spalletta interna). I pesi "centralità dominante" della v17
  ortofoto NON valgono qui perché le foto OC orbitano, non sono frontali come le ARKit.

Gate: angolo ≤70° (slider "Angolo max"), crop centrale 90%, occlusione opzionale.

**Orientamento dei piani**: deciso dalla mesh (raycast ±normale; il lato con più spazio
libero è la strada), NON dal winding dell'OBJ (che su `plane_3` è invertito). Così la
frontalità torna firmata e le camere dal lato sbagliato del muro sono escluse senza
dipendere dall'occlusione.

**Selezione squadra**: copertura greedy per famiglia di orientamento — a ogni giro entra
la foto che copre più celle ancora scoperte (NON per area totale: quello affamava le zone
a competizione densa). "Best N/piano" = tetto; "Area min" = contributo minimo per entrare
(pavimento anti-coriandoli, tenerlo ~2%: oltre esclude le foto frontali e obliqua tutto).

**Riempimento buchi** (3 passate, celle già assegnate sempre CONGELATE):
1. principale (soglia Area min)
2. "Riempi buchi": foto extra sotto soglia, solo sulle celle rosse, gate stretti
3. "Riempi residui": crescita di regione — la cella rossa eredita la foto del vicino
   assegnato (fotogramma intero, angolo ≤84°) → i balconi fuori piano restano di
   un'unica foto, deformati ma coerenti invece che frammentati. Isole senza vicini →
   migliore vista disponibile.

Extra: **consenso colore** (scarta intrusi non in mesh: veicoli/pedoni/riflessi via
mediana RGB), **esclusione manuale** foto, **bonus continuità** (rilassamento col
vicinato — la manopola giusta per "più pulito" senza perdere frontalità).

## Strumenti di diagnosi

- bordi + numeri per foto (colore stabile per id)
- ispettore click: top-8 candidate con punteggio scomposto (stessa `evaluateCell` del
  mosaico) + occlusione
- griglia celle sovraimpressa
- celle senza foto in rosso (buchi onesti)
- mesh OC texturizzata con opacità regolabile per confronto

## Limiti noti

- Parallasse verticale (davanzali/cornici in quota) NON risolvibile per selezione:
  camere tutte a ~1,65 m. Cura vera = geometria δ o scatti frontali arretrati.
- Le celle recuperate dalla 3ª passata sono più oblique/ai bordi = qualità inferiore
  (toggle per confronto).
- Percorsi dati hardcoded (sessione 6cdc). È uno strumento di messa a punto, non di
  prodotto.
