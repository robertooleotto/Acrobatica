# FacciataPro — Design Brief

> Brief di design da passare a un agente di design (es. Claude Design / Figma agent).
> Lo scopo: rivestire l'app di un'identità visiva coerente con **EdiliziAcrobatica** SENZA rompere l'architettura SwiftUI esistente.

---

## 1. Contesto

**FacciataPro** è un'app iOS nativa (SwiftUI + SwiftData) per imbianchini e ditte edili. Dal vivo in cantiere, l'utente:

1. Scatta una foto di una facciata
2. La raddrizza prospetticamente (4 angoli trascinabili)
3. Calibra una misura nota (porta = 90 cm) → ricava le dimensioni in metri
4. Disegna a dito i poligoni degli infissi da escludere
5. Simula tinte diverse (luminance preservation con Core Image)
6. Genera un preventivo PDF firmabile dal cliente

L'utente target lavora **in cantiere, con mani sporche, sole, fretta**. Dispositivo iPhone in mano, all'aperto.

---

## 2. Identità visiva

### Brand di riferimento: EdiliziAcrobatica

Vedi sito ufficiale per il mood: ottimista, professionale, italiano, "lavori in altezza" come metafora di cura ed efficienza.

### Palette colori

I colori brand sono definiti in **`FacciataPro/Theme/Theme.swift`**. **Modifica solo quel file** per cambiare i colori in tutta l'app — non cablarli inline.

| Token         | Hex        | Uso                                          |
|---------------|------------|----------------------------------------------|
| `Theme.yellow` | `#F5DC0F` | CTA principali, header, badge, brand mark   |
| `Theme.navy`   | `#0F1E48` | Testo enfatico, icone, accent serio         |
| `Theme.ink`    | `#1A1A1A` | Testo body                                  |
| `Theme.white`  | `#FFFFFF` | Sfondo principale                            |
| `Theme.success`| `#1FA463` | Stato accettato/firmato                     |
| `Theme.warning`| `#F5A524` | Da completare                                |
| `Theme.danger` | `#D9342B` | Stato rifiutato/elimina                     |

### Regola d'oro contrasto

- **Giallo brand** ha contrasto basso su bianco — usalo come **fondo** o **bordo**, mai come testo su bianco
- **Testo su giallo**: sempre `Theme.navy` o `Theme.ink`, mai grigio chiaro
- **Testo su navy**: bianco o giallo brand

### Tipografia

Sistema iOS (SF Pro). Scala consigliata:
- **Title**: `.title2.bold()` (≈22pt) per intestazioni di sezione
- **Headline**: `.headline` (≈17pt) per nomi cantiere/cliente
- **Body**: `.body` (≈17pt)
- **Caption**: `.caption` / `.caption2` per metadati
- **Numeri grandi** (m², €): `.title.monospacedDigit()` o `.title2.bold().monospacedDigit()`

### Iconografia

**SF Symbols** ovunque (è già così). Lista delle icone in uso che vale la pena vedere insieme:

| Schermata        | Icona                          |
|------------------|--------------------------------|
| Cantieri         | `house.lodge`                 |
| Listino          | `list.bullet.rectangle`       |
| Clienti          | `person.2`                    |
| Profilo          | `person.crop.circle`          |
| Camera           | `camera.fill`, `camera.viewfinder` |
| Preventivo       | `doc.text.fill`, `doc.richtext` |
| Firma            | `signature`                    |
| Add              | `plus.circle.fill`            |
| Filtro           | `line.3.horizontal.decrease.circle` |

### Stile fotografico

- Anteprima foto reale del cantiere
- I colori brand (giallo) NON vanno applicati alla foto: lasciamo che la foto si veda nei suoi colori reali, il giallo lo usiamo per i CTA sopra

### Spazi e densità

- Padding standard: `16` (carta), `24` (sezioni)
- Corner radius: `8` (chip/badge), `12` (carte), `16` (sheet)
- Tap target minimo: **56pt** (vincolo UX da briefing — utente in cantiere)
- Spaziatura tra sezioni: `16` o `24`

---

## 3. Vincoli architetturali (NON cambiare)

Questi sono **fissi**, non vanno toccati:

### Struttura file
```
FacciataPro/
├── App/                  # FacciataProApp, RootView, MainTabView
├── Models/               # 13 @Model SwiftData (NON cambiare)
├── Persistence/          # AppSchema, SeedData
├── Pricing/              # PricingEngine, PreventivoBuilder (logica pura)
├── Theme/                # Theme.swift (← modifica colori QUI)
├── Components/           # Componenti riusabili
└── Features/             # 1 cartella per sezione
```

### API delle View
Le **firme** delle View sono fisse (`@Bindable var stato`, `let onAvanti: () -> Void`, ecc.) perché collegate al coordinator del sopralluogo e ai NavigationStack. Cambia il **contenuto** del `body`, non la firma.

### Dati e logica business
- `PricingEngine`, `PreventivoBuilder`, `ColorSimulator`, `PerspectiveCorrector`, `Geometria` sono **logica pura** — NON sono View, non vanno restilizzati
- I `@Model` SwiftData restano invariati
- I `SopralluogoState` (Observable) e i loro field non si toccano

### Persistenza
Tutto via SwiftData con `@Query` e `@Bindable`. Non aggiungere ObservableObject o ViewModel custom: il pattern attuale è "View con `@Query` + business helpers".

---

## 4. Lista delle 32 schermate

Per ognuna: codice schermata, file, ruolo, elementi UI principali. **Le schermate marcate ⭐ sono quelle dove il design fa la differenza** (alta visibilità o emotional moment).

### A. Onboarding

| ⭐ | Codice | File                                          | Ruolo                          |
|----|--------|-----------------------------------------------|--------------------------------|
| ⭐ | 1.0    | `Features/Onboarding/WelcomeView.swift`      | 3 slide intro con TabView      |
|    | 1.1    | `Features/Onboarding/SetupAziendaView.swift` | Form dati ditta                |
|    | 1.x    | `Features/Onboarding/OnboardingFlowView.swift` | Coordinator                  |

### B. Cantieri (tab principale)

| ⭐ | Codice | File                                          | Ruolo                          |
|----|--------|-----------------------------------------------|--------------------------------|
| ⭐ | 2.1    | `Features/Cantieri/CantieriListView.swift`   | Lista + search + filtro stato  |
|    | 2.2    | `Features/Cantieri/NuovoCantiereView.swift`  | Sheet creazione cantiere       |
| ⭐ | 2.3    | `Features/Cantieri/DettaglioCantiereView.swift` | Dettaglio + facciate + preventivi |

### C. Sopralluogo (cuore dell'app — flusso 7 step) ⭐⭐⭐

Tutta questa sezione è il "wow" dell'app.

| ⭐ | Codice | File                                              | Ruolo                                  |
|----|--------|---------------------------------------------------|----------------------------------------|
| ⭐⭐ | 3.1    | `Features/Sopralluogo/CatturaFotoView.swift`     | Scatta o sceglie foto                 |
| ⭐⭐ | 3.2    | `Features/Sopralluogo/RaddrizzamentoView.swift`  | 4 angoli trascinabili + preview       |
| ⭐⭐ | 3.3    | `Features/Sopralluogo/CalibrazioneView.swift`    | Segmento + cm → dimensioni m          |
| ⭐⭐ | 3.4    | `Features/Sopralluogo/EsclusioneInfissiView.swift` | Tap-to-polygon infissi + lista       |
|    | 3.4b   | `Features/Sopralluogo/AggiungiExtraView.swift`   | Sheet balconi/cornicioni              |
| ⭐⭐ | 3.5    | `Features/Sopralluogo/SimulazioneTinteView.swift` | Palette + 4 varianti + prima/dopo    |
|    | 3.6    | `Features/Sopralluogo/SelezioneCicloView.swift`  | Picker ciclo + voci accessorie        |
| ⭐ | 3.7    | `Features/Sopralluogo/RiepilogoFacciataView.swift` | Riepilogo + salva                    |
|    | 3.x    | `Features/Sopralluogo/SopralluogoCoordinator.swift` | NavigationStack del flusso          |

### D. Preventivo

| ⭐ | Codice | File                                              | Ruolo                                  |
|----|--------|---------------------------------------------------|----------------------------------------|
| ⭐⭐ | 4.1    | `Features/Preventivo/AnteprimaPreventivoView.swift` | Form + breakdown live + CTA         |
| ⭐⭐ | 4.2    | `Features/Preventivo/PDFPreventivoView.swift`    | Anteprima PDF + Share + Firma         |
| ⭐ | 4.3    | `Features/Preventivo/FirmaClienteView.swift`     | Canvas firma + nome + accetta         |

### E. Listino (tab)

| ⭐ | Codice | File                                              | Ruolo                                  |
|----|--------|---------------------------------------------------|----------------------------------------|
|    | 5.1    | `Features/Listino/ListinoHomeView.swift`         | Hub con 3 card                         |
|    | 5.2    | `Features/Listino/ProdottiListView.swift`        | CRUD prodotti                          |
|    | 5.2b   | `Features/Listino/ProdottoEditView.swift`        | Sheet edit                             |
|    | 5.3    | `Features/Listino/CicliListView.swift`           | CRUD cicli                             |
|    | 5.3b   | `Features/Listino/CicloEditView.swift`           | Sheet edit                             |
|    | 5.4    | `Features/Listino/VociAccessorieView.swift`      | CRUD voci accessorie                   |

### F. Clienti (tab)

| ⭐ | Codice | File                                              | Ruolo                                  |
|----|--------|---------------------------------------------------|----------------------------------------|
|    | 6.1    | `Features/Clienti/ClientiListView.swift`         | Lista + search                         |
|    | 6.2    | `Features/Clienti/ClienteEditView.swift`         | Sheet edit                             |

### G. Profilo (tab)

| ⭐ | Codice | File                                              | Ruolo                                  |
|----|--------|---------------------------------------------------|----------------------------------------|
| ⭐ | 7.1    | `Features/Profilo/ProfiloHomeView.swift`         | Header + sezioni                       |
|    | 7.2    | `Features/Profilo/PersonalizzaPDFView.swift`     | (placeholder)                          |
|    | 7.3    | `Features/Profilo/DefaultPreventiviView.swift`   | Default `@AppStorage`                  |

### H. App-level

| ⭐ | Codice | File                                              | Ruolo                                  |
|----|--------|---------------------------------------------------|----------------------------------------|
|    | 0.0    | `App/RootView.swift`                              | Switch onboarding ↔ MainTabView        |
|    | 0.1    | `App/MainTabView.swift`                           | TabView 4 tab                          |

---

## 5. Componenti riusabili da creare

Suggeriti per dare coerenza:

- **`BrandButton`** (.primary / .secondary / .destructive): `minHeight: 56`, fondo giallo per primary, bordo navy per secondary, full-width default. Usato in tutti i CTA.
- **`StatoChip`** (per StatoCantiere): pill con colore semantico (warning per bozza, accent per inviato, success per accettato, danger per rifiutato).
- **`MetricCard`**: card con label piccola sopra + numero grande sotto. Usato per superficie, totali.
- **`SectionHeader`**: testo uppercase, bold, 11pt, navy.6 con divider sottile sotto.
- **`PhotoFrame`**: contenitore foto con ratio 4:3 e corner radius 12.
- **`Pill`**: per tag generici (categoria prodotto, tipo cliente).

Mettili in **`FacciataPro/Components/`**. NON sostituire `PlaceholderView` esistente.

---

## 6. Cosa serve da Claude Design

Per ogni schermata ⭐⭐ (le 5 chiave del sopralluogo + 2 del preventivo):

1. **Mockup statico** (immagine o codice SwiftUI)
2. **Lista componenti** che usa (riusando quelli sopra)
3. **Spiegazione delle scelte cromatiche** (dove giallo, dove navy)

Per le altre schermate basta:
- **Indicare i token** da applicare (background, testo, accent)
- **Eventuali ricomposizioni di layout** se l'attuale è confuso

---

## 7. Cosa NON deve fare Claude Design

- ❌ NON aggiungere librerie esterne (SnapKit, Lottie, ecc.)
- ❌ NON cambiare le firme delle View pubbliche
- ❌ NON spostare logica di business dentro le View
- ❌ NON cambiare i nomi dei `@Model` o dei field
- ❌ NON usare `Color(.red)` o `.tint` cablati: solo `Theme.*`
- ❌ NON aggiungere animazioni gratuite (vincolo da briefing UX punto 10)

---

## 8. File da leggere prima

- `BRIEFING.md` — specifica funzionale completa
- `README.md` — stato attuale e cosa funziona end-to-end
- `FacciataPro/Theme/Theme.swift` — sorgente di verità dei colori
- `FacciataPro/Components/PlaceholderView.swift` — esempio di componente esistente

---

Versione brief: 1.0 — generato dopo Fasi 1-5 complete.
