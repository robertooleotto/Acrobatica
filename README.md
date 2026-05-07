# FacciataPro — iOS skeleton

App iOS nativa SwiftUI + SwiftData per imbianchini e ditte edili: misura facciate da foto, simula tinte, calcola preventivi, genera PDF.

> Vedi `BRIEFING.md` per la specifica funzionale completa (1.0 — MVP-first, 12 settimane di roadmap).

## Stato attuale

**Skeleton end-to-end (Fase 1 strutturale).** Tutti i sorgenti per:
- 13 model SwiftData (sezione 4 del briefing)
- Schema + dati seed precaricati (10 prodotti, 3 cicli, 4 voci accessorie)
- `PricingEngine` con firma stabile + 8 unit test sui calcoli critici
- 32 view SwiftUI per le 7 sezioni dell'app, navigazione end-to-end

Le view sono di due tipi:
- **Funzionali**: tutto il listino (CRUD prodotti/cicli/voci), clienti CRUD, cantieri CRUD, onboarding setup ditta, profilo, anteprima preventivo, configurazione default. Persistenza reale.
- **Placeholder con TODO**: schermate Computer Vision (cattura foto, raddrizzamento, calibrazione, infissi, simulazione tinte) e PDF generation. Hanno UI, struttura e elenco di cosa manca, ma niente CV/PDFKit. Sono le fasi 3, 4, 5 della roadmap.

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

1. **Primo avvio**: vedi l'onboarding (3 slide + form setup ditta). Salvando entri nel main tab bar.
2. **Tab Cantieri**: vuoto. Crei un cantiere (con un cliente nuovo o esistente).
3. **Tab Listino**: già popolato con i 10 prodotti, 3 cicli, 4 voci accessorie seed. Puoi creare/modificare/eliminare tutto.
4. **Tab Clienti**: CRUD completo.
5. **Tab Profilo**: editable, default preventivi salvati in `@AppStorage`.
6. **Sopralluogo** (da Dettaglio cantiere → "Nuovo sopralluogo"): naviga tutti e 7 gli step in sequenza (placeholder UI, niente CV) e salva la facciata con superficie 0 m² alla fine.

## Roadmap (dal briefing)

- ✅ **Fase 1 — Foundation**: model, persistence, onboarding, cantieri/clienti/profilo CRUD
- ✅ **Fase 2 — Listino**: prodotti/cicli/voci CRUD + seed
- ✅ **PricingEngine**: firma stabile + test
- 🚧 **Fase 3 — Sopralluogo CV**: cattura foto, omografia, calibrazione, infissi
- 🚧 **Fase 4 — Simulazione colore**: blending luminance preservation con Core Image
- 🚧 **Fase 5 — PDF**: generazione con PDFKit
- 🚧 **Fase 6 — Polish**: firma canvas, multi-facciata, extra
- 🚧 **Fase 7 — V2**: auto-detect, SAM, sync cloud

Vedi i `// TODO:` e `PlaceholderView` con la lista delle cose da implementare per ogni schermata.

## Convenzioni

- **Linguaggio**: identificatori e UI in italiano (dominio business). Solo termini Swift/Apple in inglese.
- **Tap target**: ≥ 56pt (vedi `minHeight: 56` sui CTA).
- **Offline-first**: nessuna chiamata di rete. Backend in fase 7.
- **Salvataggio**: `try? context.save()` dopo ogni mutazione persistente.
- **Override manuale**: tutti gli step di calibrazione/calcolo permettono input diretto (anche se nei placeholder è solo segnalato).
