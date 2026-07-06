# Handoff: Acrobatica — App iOS completa (21 schermate)

## Overview
Prototipo ad alta fedeltà dell'intera app iOS **Acrobatica** (rilievo 3D di facciate e preventivazione per imprese edili): il flusso completo a 7 fasi del brief di design — Accesso, Cantieri, Cattura AR, Elaborazione 3D, Marcatura, Preventivo, Anagrafiche — con stati (empty/loading/error), 2–3 varianti per le 6 schermate nuove, e layout iPad landscape per Cattura ed Editor 3D.

**Target di implementazione:** il codebase esistente `robertooleotto/Acrobatica` → `ios/Acrobatica/` (SwiftUI). 15 schermate esistono già nel codice e vanno solo estese/raccordate; 6 sono nuove e vanno implementate da zero.

## About the Design Files
I file in `design_files/` sono **riferimenti di design creati in HTML/JSX** — prototipi che mostrano aspetto e comportamento previsti, **non codice di produzione da copiare**. Il compito è **ricreare queste schermate in SwiftUI** dentro il codebase esistente, usando:
- i token già presenti in `ios/Acrobatica/DesignSystem/Theme.swift` (mappano 1:1 con i valori qui sotto),
- i componenti esistenti in `DesignSystem/Components/` (`BrandButton`, `GlassPill`, `ShutterButton`, `FrameStrip`),
- **SF Symbols reali** al posto delle icone stroke del prototipo (la mappa è sotto, sezione Assets).

I file `.jsx` sono la specifica esatta: ogni misura, colore e font è scritto inline — usali come fonte dei valori pixel.

## Fidelity
**High-fidelity.** Colori, tipografia, spaziature, raggi e copy sono definitivi e vanno replicati fedelmente. Uniche eccezioni: le icone (usare SF Symbols) e le immagini facciata/ortofoto (nel prototipo sono placeholder stilizzati; nell'app reale sono output della pipeline).

## Struttura di navigazione (nuova, da implementare)
Tab bar a 5 voci sulle schermate radice: **Home (0.3) · Cantieri (1.1) · Preventivi (5.1) · Clienti (6.1) · Profilo (6.4)**. Le schermate di dettaglio usano push con back. I fogli (1.2 Nuovo cantiere, Nuovo cliente, Nuova voce listino) sono sheet con radius superiore 28.

## Screens / Views

### Fase 0 · Accesso (🆕 — 3 schermate, con varianti)
- **0.1 Splash** — Variante A: navy pieno, tile giallo r24 84px con glifo building, wordmark bianco 32 bold, spinner; auto-avanza a 0.2 dopo ~2.4s. Variante B: paper, logo navy in basso a sinistra, banda gialla inferiore con progress bar navy e versione mono.
- **0.2 Login** — email + password (toggle mostra), segmented **Operatore | Senior**, CTA gialla "Accedi" (spinner in loading), link "Password dimenticata?". **Stato errore:** bordo campo danger + messaggio "Inserisci la password per continuare". Variante A: card centrale su paper con logo sopra. Variante B: header navy con wordmark + tagline, sheet paper r28 con il form.
- **0.3 Home / Dashboard** — saluto "Ciao, ‹nome›" (30 bold) + data; 3 MetricCard KPI (Cantieri attivi / Da inviare [evidenziata gialla] / m² questo mese); azioni rapide "Nuovo cantiere" (primary) + "Nuovo rilievo" (secondary) affiancate; "Ultimi cantieri" (3 righe + Vedi tutti); "Preventivi recenti" (2 righe). **Empty state:** icona building + "Inizia da qui" + CTA "Crea il tuo primo cantiere". Variante B: header navy r28 inferiore con KPI dentro (numeri gialli). Variante C: hero card gialla "Nuovo rilievo" + KPI mono in linea + lista cantieri.

### Fase 1 · Cantieri (✅ esistenti: `CantieriListView`, `DettaglioCantiereView`)
- **1.1 Lista** — come nel codice; aggiunto empty state ("Nessun cantiere" / "Tocca + in alto per crearne uno") e tab bar.
- **1.2 Nuovo cantiere (sheet)** — grabber, titolo 20 semibold, campi Nome / Indirizzo / Cliente (input grigi r12, h48, label micro uppercase), CTA "Crea cantiere".
- **1.4 Dettaglio** — come nel codice: card header cantiere + lista facciate con StatoChip + "Nuovo rilievo".

### Fase 2 · Cattura (✅ `CatturaARView`)
- **2.1 Live AR** — camera full-screen, reticolo giallo, GlassPill `REC · mm:ss` (mono), chip baseline (verde/ambra), hint operativi, shutter giallo 76px, pill navy "Stop". Aggiunto contatore frame.
- **2.2 Frame strip** — rullino 56px, ultimo frame bordato giallo con check; undo elimina l'ultimo.
- **iPad landscape:** stesso chrome, posizioni assolute adattate (vedi `shell.jsx` → prop `pad`).

### Fase 3 · Elaborazione 3D (✅ `RisultatoPanoramaView`, `EditorMesh3DView`, `RectifyFacadeView`, `MeasureScaleView`)
- **3.1 Risultato** — **stato elaborazione** (card ambra con spinner, 2 fasi: "Elaborazione in corso" → "Calcolo metrature…", ortofoto al 45% di opacità) poi metriche: 3 MetricCard (Area netta evidenziata), lista aperture, CTA: Editor 3D / Rettifica (mezza larghezza) + Definisci facciata / Imposta scala / Genera preventivo.
- **3.2 Editor 3D** — sfondo `#0b0f1c`, mesh con wireframe giallo e vertici, 5 strumenti in glass circle (box lavoro, lazo, pennello facce, piano-zero, snap; attivo = anello giallo), pill info mono "12.4k vertici · 24.1k facce", CTA gialla "Conferma mesh". Anche iPad landscape.
- **3.4 Rettifica** — immagine prospettica con 4 handle gialli angolari + quadrilatero tratteggiato; CTA "Raddrizza → ortofoto" anima il raddrizzamento (transform .6s); chip verde "Ortofoto generata"; poi "Continua — Imposta scala".
- **3.5 Misura scala** — linea di misura gialla a 2 punti sull'ortofoto, etichetta mono `4.50 m`, campo "Lunghezza reale" con suffisso m, readout "Scala risultante: 8.3 mm/px", CTA "Conferma scala".

### Fase 4 · Marcatura (✅ `MarcaturaFacciataView`)
- **4.1 Zone e aperture** — ortofoto con zone gialle tratteggiate etichettate (`Z1 · 258.4 m²`), aperture navy-wash bordate bianco, chip strumento scorrevoli (Zona lavoro / Finestra / Porta / Balcone; attivo = navy con testo giallo), 3 MetricCard, CTA "Genera preventivo".

### Fase 5 · Preventivo (✅ `ListaPreventiviView`, `AnteprimaPreventivoView`, `PDFPreventivoView`, `FirmaClienteView`)
- **5.1 Lista** — segmented Tutti/Bozze/Inviati/Accettati, righe con numero mono + cliente + totale mono bold + StatoChip; empty state per filtro.
- **5.2 Editor** — card cliente, voci di lavoro (righe grigie r12 con q × €/u = subtotale, icona modifica), **"Aggiungi da listino"** (apre 6.3 in selezione multipla), card Manodopera (ore × tariffa), card totali giallo-wash (Imponibile / IVA 22% / TOTALE), CTA PDF + Firma.
- **5.4 PDF** — pagina A4 (aspect 1:1.414) con wordmark, riga gialla, dati cliente, voci, totale evidenziato, doppia firma; CTA "Condividi PDF".
- **5.5 Firma** — testo di accettazione con numero e totale, area firma disegnabile (linea tratteggiata + "✕ Firma qui"), Cancella / "Conferma accettazione" (disabilitata finché vuota); **stato successo:** check verde, "Preventivo accettato", CTA di ritorno.

### Fase 6 · Anagrafiche (🆕 — 4 schermate, varianti A/B)
- **6.1 Clienti** — ricerca (campo grigio r12 h42), righe con avatar iniziali (tile navy, iniziali gialle), nome + città + N cantieri; sheet nuovo cliente (Nome/Telefono/P.IVA/Email/Indirizzo); empty state (anche per ricerca senza risultati). Variante B: raggruppamento alfabetico con lettere mono.
- **6.2 Cliente dettaglio** — card header (avatar, nome, P.IVA) + righe contatto tappabili (telefono/email/indirizzo con tile icona 34px); sezioni Cantieri e Preventivi; CTA "Nuovo cantiere per questo cliente". Variante B: hero navy con avatar giallo e 3 azioni circolari (Chiama/Email/Mappa).
- **6.3 Listino** — voci raggruppate per categoria (Superfici, Aperture e contorni, Struttura e accesso, Manodopera), riga = descrizione + unità mono + prezzo mono; sheet nuova voce; **modalità selezione** (da 5.2): checkbox navy, CTA flottante "Inserisci N voci nel preventivo". Variante B: filtro a chip per categoria.
- **6.4 Impostazioni / Profilo** — card profilo (avatar, nome, email, chip ruolo); sezione Preventivi (Tariffa oraria € 35/h, IVA 22%, Validità 30 giorni, Prefisso PRV); sezione App (Dati e sync, Informazioni, Versione); CTA "Esci" ghost in danger. Variante B: hero navy centrato.

## Interactions & Behavior
- Happy path: Login → Home → Cantiere → Cattura (Stop) → Risultato (elaborazione ~2.8s) → Editor 3D → Rettifica → Scala → Marcatura → Preventivo → PDF → Firma → successo.
- Press: scale(0.98); disabled: opacity 0.4.
- Sheet: rise .3s ease; rettifica: transform .6s ease; spinner: rotate .9s linear.
- Stati colore: verde = ok/elaborato/accettato · ambra = in corso/inviato · rosso = errore/rifiutato (chip = testo 10 semibold nel tint su wash ~12%).
- Login: submit senza password → errore inline; con password → spinner ~1s → Home.

## State Management
- Route stack + tab attiva; cantiere/rilievo/cliente/preventivo selezionati.
- Cattura: array frame, timer, stato baseline (3 soglie).
- Risultato: fase elaborazione (in corso → metrature → pronto).
- Preventivo: voci[], ore, tariffa; totali derivati (imponibile, IVA 22%, totale, formato it-IT).
- Listino: modalità selezione + set voci selezionate → inserimento in preventivo.
- Firma: strokes[]; abilita conferma solo se presente.

## Design Tokens (= `Theme.swift`)
- Colori: yellow `#F5DC0F` · navy `#0F1E48` · ink `#1A1A1A` · paper `#F7F6F2` · grayBg `#EEECE6` · white `#FFF` · hair navy@8% · hair2 navy@16% · muted navy@55% · success `#1FA463` · warning `#F5A524` · danger `#D9342B` (wash chip ~12–18%).
- Tipografia: SF Pro (system). Display 34 bold · Title 22/20/18/17/15 semibold · Body 15/14/13 · Caption 12 medium · Micro 10 semibold uppercase kerning 0.5 · Mono (SF Mono) 13 semibold per misure/valute/timer.
- Spacing: 4/8/12/16/24/32; gutter schermo 16; gap card 12; padding card 14–16.
- Radius: 8 · 12 · 14 · 16–18 (card) · 22 (bottoni h52) · 28 (sheet) · pill 999.
- Ombre: nessuna sulle card (solo hairline); glass/PiP/shutter come da design system.

## Assets
- **Icone:** il prototipo usa stroke-icons geometria Lucide (`components.jsx` → `ACRO_ICONS`, estese in `base.jsx`). In SwiftUI usare SF Symbols: building.2.fill, camera.fill, rectangle.stack.fill, stop.fill, xmark, viewfinder, arrow.uturn.backward, ruler, square.and.arrow.up, chevron.right, plus, mappin.and.ellipse, signature, doc.text, person.2, person.crop.circle, gearshape, phone, envelope, eurosign, rectangle.portrait.and.arrow.right, pencil, trash, cube, paintbrush, lasso, grid, arrow.triangle.2.circlepath, tag, eye, lock, info.circle, magnifyingglass, bolt, checkmark.
- **Wordmark:** placeholder (tile giallo + glifo building + "Acrobatica" bold) — non esiste logo ufficiale nel repo.
- **Immagini facciata/ortofoto:** placeholder stilizzati (`FacadeBackdrop`); nell'app reale arrivano dalla pipeline (es. `facade_ortho.png`).

## Files
- `design_files/Acrobatica Prototype.dc.html` — entry del prototipo (rail di navigazione + host).
- `design_files/app/components.jsx` — atomi del design system (BrandButton, Card, StatoChip, MetricCard, Tile, GlassPill, icone).
- `design_files/app/base.jsx` — helper condivisi: NavBar, Segmented, Field, Sheet, TabBar, EmptyState, icone extra, frame iPad.
- `design_files/app/screens-flow1.jsx` — Fasi 1–3 (Cantieri, Cattura AR, Risultato, Editor 3D, Rettifica, Scala).
- `design_files/app/screens-flow2.jsx` — Fasi 4–5 (Marcatura, Preventivi, Editor preventivo, PDF, Firma).
- `design_files/app/screens-new.jsx` — Fase 0 + Fase 6 con tutte le varianti A/B/C.
- `design_files/app/shell.jsx` — dati seed, mappa route, shell di navigazione, frame iPhone/iPad.
