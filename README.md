# FacciataPro — iOS skeleton

App iOS nativa SwiftUI + SwiftData per imbianchini e ditte edili: misura facciate da foto, simula tinte, calcola preventivi, genera PDF.

> Vedi `BRIEFING.md` per la specifica funzionale completa (1.0 — MVP-first, 12 settimane di roadmap).

## Stato attuale

**Fasi 1-5 funzionanti, Fase 6 parziale (firma).** L'app è utilizzabile end-to-end:

- 13 model SwiftData con relazioni complete
- Schema + dati seed precaricati (10 prodotti, 3 cicli, 4 voci accessorie)
- `PricingEngine` (logica pura) + 8 unit test sui calcoli critici
- `PreventivoBuilder`: mappatura model → PricingInput, persiste Preventivo/VocePreventivo
- Pipeline Computer Vision: scatto foto → raddrizzamento prospettico (CIPerspectiveCorrection) → calibrazione segmento → tap-poligoni per infissi
- Simulazione colore: luminance preservation con CIColorControls + CIMultiplyCompositing, palette 8 tinte + HEX custom, 4 varianti
- Generazione PDF con PDFKit (header logo, blocco cliente/cantiere, tabella voci con paginazione, totali, firma)
- Firma cliente: canvas SwiftUI con DragGesture, salvata come PNG

## Requisiti

- Xcode 15+
- iOS 17+ (richiesto da SwiftData)
- Swift 5.9+

## Setup del progetto Xcode

I sorgenti sono organizzati per feature ma **non c'è ancora un `.xcodeproj`** (verrà creato in locale per evitare commit di file generati). Procedi così:

1. **Xcode → File → New → Project → iOS → App**
2. Configura:
   - Product Name: `FacciataPro`
   - Interface: `SwiftUI`
   - Language: `Swift`
   - Storage: `SwiftData`
   - Include Tests: ✅
3. Salva il progetto **dentro la repo** (es. `~/Acrobatica/FacciataPro.xcodeproj`)
4. **Elimina** i file generati di default da Xcode:
   - `FacciataProApp.swift`
   - `ContentView.swift`
   - eventuale `Item.swift`
   - `FacciataProTests.swift` nel target test
5. **Trascina le cartelle sorgente in Xcode** (sidebar di sinistra):
   - Trascina `FacciataPro/` (cartella) → "Create groups" → target `FacciataPro`
   - Trascina `FacciataProTests/PricingEngineTests.swift` → target `FacciataProTests`
6. **Info.plist** — aggiungi (per le fasi successive):
   - `NSCameraUsageDescription`: *"FacciataPro usa la fotocamera per scattare foto delle facciate da misurare."*
   - `NSPhotoLibraryUsageDescription`: *"FacciataPro accede alle foto se vuoi importare immagini esistenti."*
7. **Build** (`⌘B`) e **Run** (`⌘R`) su simulatore iOS 17+

Se preferisci, una volta che il `.xcodeproj` esiste, committalo (è la convenzione iOS standard) — il `.gitignore` già esclude `xcuserdata/` e gli stati locali di Xcode.

## Eseguire i test

```
⌘U   # in Xcode con il target FacciataProTests selezionato
```

oppure da CLI:

```bash
xcodebuild test -scheme FacciataPro -destination 'platform=iOS Simulator,name=iPhone 15'
```

Gli unit test coprono i casi critici della pricing engine:
- somma corretta superficie netta (lorda − esclusi + extra)
- protezione contro superficie negativa
- arrotondamento verso l'alto al formato di vendita
- coefficiente di abbondamento applicato
- manodopera per mq netti
- voci accessorie a corpo non scalate per superficie
- ordine: subtotale → margine → IVA
- guard su resa = 0

## Struttura sorgenti

```
FacciataPro/
├── App/                  # Entry point, RootView, MainTabView
├── Models/               # 13 @Model SwiftData + enums
├── Persistence/          # ModelSchema, SeedData
├── Pricing/              # PricingEngine (logica pura, testabile)
├── Components/           # PlaceholderView riusabile
└── Features/
    ├── Onboarding/       # 1.1 Welcome, 1.2 Setup ditta
    ├── Cantieri/         # 2.1 Lista, 2.2 Nuovo, 2.3 Dettaglio
    ├── Sopralluogo/      # 3.1–3.7 + 3.4b (placeholder per CV)
    ├── Preventivo/       # 4.1 Anteprima, 4.2 PDF, 4.3 Firma
    ├── Listino/          # 5.1–5.4 (CRUD funzionante)
    ├── Clienti/          # 6.1–6.2 (CRUD funzionante)
    └── Profilo/          # 7.1–7.3
FacciataProTests/
└── PricingEngineTests.swift
```

## Cosa funziona davvero, end-to-end

Avviando l'app:

1. **Primo avvio**: onboarding (3 slide + form setup ditta), poi main tab bar.
2. **Crea cantiere** con cliente (esistente o nuovo).
3. **Sopralluogo** (7 step):
   - Scatta o seleziona foto (UIImagePickerController + PhotosPicker)
   - Trascina i 4 angoli sul perimetro della facciata, applica raddrizzamento
   - Trascina i 2 punti gialli su un riferimento noto, inserisci la misura in cm → calcola pixelPerCm e dimensioni in metri
   - Tap-to-polygon per ogni infisso, assegna tipo + nome → calcola area in m²
   - Tinte: scegli da palette o HEX, applica a tutta la facciata, fino a 4 varianti
   - Selezione ciclo + voci accessorie
   - Riepilogo + salva
4. **Genera preventivo** dal dettaglio cantiere:
   - PreventivoBuilder esegue PricingEngine per ogni facciata col suo ciclo
   - Aggiungi voci accessorie con quantità
   - Margine, IVA, validità (default da @AppStorage)
   - Salva → genera PDF A4 con tabella voci, totali, condizioni, spazio firma
5. **Firma cliente**: canvas SwiftUI, salva PNG in Preventivo.firmaClienteData
6. **Listino / Clienti**: CRUD completo, prodotti/cicli/voci precaricati al primo avvio

## Roadmap (dal briefing)

- ✅ **Fase 1 — Foundation**: model, persistence, onboarding, cantieri/clienti/profilo CRUD
- ✅ **Fase 2 — Listino**: prodotti/cicli/voci CRUD + seed
- ✅ **PricingEngine**: firma stabile + test
- ✅ **Fase 3 — Sopralluogo CV**: cattura foto, raddrizzamento (CIPerspectiveCorrection), calibrazione, esclusione infissi (poligoni a dito + shoelace)
- ✅ **Fase 4 — Simulazione colore**: luminance preservation (full-facade, fino a 4 varianti)
- ✅ **Fase 5 — PDF**: generazione PDFKit con paginazione, header, tabella voci, totali, firma
- 🟡 **Fase 6 — Polish**: firma canvas ✅, multi-facciata già supportata, restano duplica/elimina cantiere, zone-based simulation
- 🚧 **Fase 7 — V2**: auto-detect Vision (VNDetectRectanglesRequest), SAM, sync cloud, palette NCS/RAL

Cose ancora marcate come `TODO:` nei sorgenti:
- Auto-detect angoli con Vision in raddrizzamento
- Griglia overlay con CMMotionManager nella cattura foto
- Selezione zone con poligoni nella simulazione tinte (CIBlendWithMask)
- Personalizza PDF (logo upload, colore accent, footer custom)

## Convenzioni

- **Linguaggio**: identificatori e UI in italiano (dominio business). Solo termini Swift/Apple in inglese.
- **Tap target**: ≥ 56pt (vedi `minHeight: 56` sui CTA).
- **Offline-first**: nessuna chiamata di rete. Backend in fase 7.
- **Salvataggio**: `try? context.save()` dopo ogni mutazione persistente.
- **Override manuale**: tutti gli step di calibrazione/calcolo permettono input diretto (anche se nei placeholder è solo segnalato).
