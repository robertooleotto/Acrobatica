# Brief di Design — App Acrobatica

**Per:** Carlo
**Strumento:** Claude (con connettore Figma attivo)
**Obiettivo:** progettare in Figma l'intera app iOS "Acrobatica" — dal design system alle 21 schermate del flusso — partendo dai token reali già presenti nel codice.

---

## 0. Come usare questo documento con Claude + Figma

Questo brief è pensato per essere dato in pasto a Claude con il **connettore Figma collegato**. Passi operativi:

1. **Collega Figma** a Claude (impostazioni connettori su claude.ai, oppure `/mcp` in Claude Code).
2. **Crea un file Figma** dedicato: `Acrobatica — App iOS`.
3. Dai a Claude questo documento e chiedi, nell'ordine:
   - «Costruisci in Figma il **design system** della sezione 3 (variabili colore, tipografia, spacing, radius) come Figma Variables + stili.»
   - «Crea i **componenti base** della sezione 4 come Figma Components con varianti.»
   - «Genera le **schermate** della sezione 6, una fase alla volta, usando i componenti e i token appena creati.»
4. Le **skill Figma** giuste da far usare a Claude: `figma-generate-library` (design system e componenti), `figma-generate-design` (assemblaggio delle schermate), `figma-swiftui` (sync bidirezionale Figma ↔ SwiftUI, dato che l'app è già in SwiftUI).

> ⚠️ Regola d'oro: **niente valori hardcoded** nelle schermate. Ogni colore/spazio/raggio deve puntare a una Variable del design system, così un cambio di palette si propaga ovunque.

**Target device:** iPhone (portrait, 393×852 pt — iPhone 15/16) come primario. iPad (landscape libero) come secondario per l'editor 3D e la cattura. Design mobile-first.

---

## 1. Cos'è Acrobatica

App da campo per operatori che fanno **rilievo e preventivazione di facciate** (ristrutturazione/manutenzione con accesso su fune). Il ciclo:

**Cantiere → rilievo facciata con foto AR → elaborazione 3D (mesh + ortofoto) → marcatura zone e aperture → preventivo → PDF → firma cliente.**

**Utenti:**
- **Operatore** — sul campo, guanti, luce forte, una mano sola. Cattura e rilievo. UI a tocchi grandi, alto contrasto.
- **Senior** — in ufficio, rivede preventivi, prezzi, invii. Vede tutto.

**Tono visivo:** professionale, industriale-pulito. Navy + giallo cantiere. Superfici piatte, niente gradienti decorativi, molto spazio bianco, bordi hairline.

---

## 2. Principi di design

- **Mobile-first, una mano.** Azioni primarie in basso, pollice-friendly. Bottoni min 52 pt d'altezza.
- **Alto contrasto per esterni.** Testo navy su carta chiara; overlay AR con vetro scuro (glass) sopra la camera.
- **Card piatte** con bordo hairline (navy 8%) e raggio 14–18. Niente ombre pesanti.
- **Stato sempre visibile.** Ogni rilievo/preventivo mostra un chip di stato colorato.
- **Empty state curati.** Ogni lista vuota ha icona + titolo + CTA.

---

## 3. Design System (token reali dal codice)

Fonte: `ios/Acrobatica/DesignSystem/Theme.swift`. Ricrea questi come **Figma Variables** in una collezione `Theme`.

### 3.1 Colori

| Token | HEX | Uso |
|---|---|---|
| `yellow` | `#F5DC0F` | Accento/brand, CTA primarie, evidenze |
| `navy` | `#0F1E48` | Testo primario, superfici scure, icone |
| `ink` | `#1A1A1A` | Testo massimo contrasto |
| `paper` | `#F7F6F2` | Sfondo app |
| `grayBg` | `#EEECE6` | Sfondo campi/righe interne |
| `white` | `#FFFFFF` | Superficie card |
| `hair` | `navy @ 8%` | Bordo hairline card |
| `hair2` | `navy @ 16%` | Bordo hairline marcato |
| `muted` | `navy @ 55%` | Testo secondario, icone soft |
| `success` | `#1FA463` | Stato ok/elaborato/accettato |
| `warning` | `#F5A524` | Stato in corso/inviato |
| `danger` | `#D9342B` | Errore/rifiutato |

### 3.2 Tipografia (SF Pro / system)

| Stile | Size | Weight | Uso |
|---|---|---|---|
| Display | 34 | Bold | Titoli grandi/dashboard |
| Title | 22 | Semibold | Titoli schermata (scala: 22/20/18/17/15) |
| Body | 15 | Regular | Testo corrente (scala: 15/14/13) |
| Caption | 12 | Medium | Metadati, etichette |
| Mono | 13 | Semibold | Numeri/misure (m², €, ppm) |

Etichette "occhiello" (es. `CLIENTE`): 10 pt, Semibold, kerning 0.5, colore `muted`.

### 3.3 Spacing (scala 4-pt)

`xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32`. Padding standard card = 14–16. Margine schermo orizzontale = 16.

### 3.4 Radius

`s 8 · m 14 · l 22 · xl 28 · pill 999`. Card = 14–18. Bottoni primari = 22.

---

## 4. Componenti base (da creare come Figma Components)

Fonte: `ios/Acrobatica/DesignSystem/Components/`. Ricrea con **varianti**.

| Componente | Varianti / props | Spec |
|---|---|---|
| **BrandButton** | `primary` · `secondary` · `ghost`; con/senza icona | Altezza 52, full-width, radius 22, size 17 Semibold. primary = fill `yellow`, testo `navy`. secondary = fill `paper`, bordo `navy @16%`. ghost = trasparente, bordo `navy @16%`. |
| **CircleIconButton** | size 44 default | Cerchio, `ultraThinMaterial`, icona 18 Semibold. Per chrome AR. |
| **PillButton** | icona+testo | Capsule, fill `navy`, testo `yellow` 15 Semibold, padding 18×12. Es. "Stop". |
| **GlassPill** | contenuto libero / solo icona | Capsule glass (`ultraThinMaterial`), testo bianco 14 Semibold, bordo bianco 12%. Overlay sopra camera AR. |
| **StatoChip** | tint = muted/warning/success/danger | Capsule, testo 10 Semibold nel tint, fill tint @12%. |
| **Card** | default | `white`, radius 16–18, bordo `hair` 1px, padding 14–16. Contenitore base ovunque. |
| **ListRow** | cantiere / rilievo / preventivo | Card + icona 56×56 (tile navy o grayBg) + titolo/sottotitolo + chevron. |
| **AvatarTile** | building / doc / stack | Tile 56×56 radius 12–14, fill `navy` con icona `yellow`, o `grayBg` con icona soft. |
| **SectionHeader** | con/senza count/azione | Titolo 15–17 Semibold `navy` + eventuale contatore/`+`. |
| **EmptyState** | per lista | Icona 44–48 light `muted` + titolo + sottotitolo + CTA `BrandButton`. |
| **MetricCard** | KPI dashboard | Numero grande (Display) + label caption. Per Home. |

---

## 5. Struttura del file Figma

Organizza in **pagine**:

1. `📐 Foundations` — variabili colore, tipografia, spacing, radius, griglia.
2. `🧩 Components` — la libreria della sezione 4.
3. `🗺️ Flow` — la mappa del flusso (sezione 6) con i frame collegati (FigJam-style o prototype links).
4. `📱 Screens — Fase 0…6` — le schermate, una sezione per fase.
5. `🔦 States` — varianti empty/loading/error/success dove serve.

**Naming frame:** `⟨fase.numero⟩ ⟨Nome⟩` — es. `1.4 Cantiere / Dettaglio`, `5.2 Preventivo / Editor voci`.

---

## 6. Flusso completo — 7 fasi, 21 schermate

Legenda: ✅ esiste già nel codice (ricostruire in Figma fedelmente) · 🆕 nuova (da progettare da zero).

### Fase 0 · Accesso
- `0.1 Splash / Launch` 🆕 — logo Acrobatica su navy, spinner.
- `0.2 Login` 🆕 — email + password, selettore ruolo (Operatore/Senior), CTA accedi.
- `0.3 Home / Dashboard` 🆕 — saluto, KPI (cantieri attivi, preventivi in sospeso, m² rilevati), azioni rapide (Nuovo cantiere, Nuovo rilievo), ultimi cantieri.

### Fase 1 · Cantieri
- `1.1 Cantieri / Lista` ✅ — lista card cantiere, `+` nuovo, empty state.
- `1.2 Cantiere / Nuovo (sheet)` ✅ — form: nome, indirizzo, cliente.
- `1.4 Cantiere / Dettaglio` ✅ — header cantiere + lista facciate (rilievi) con chip stato, CTA cattura.

### Fase 2 · Cattura
- `2.1 Cattura AR / Live` ✅ — camera full-screen, overlay: griglia livello, bolla/pitch ladder, bussola, ghost del frame precedente, shutter, contatore frame.
- `2.2 Frame strip` ✅ — rullino orizzontale dei frame catturati, elimina ultimo, conferma.

### Fase 3 · Elaborazione 3D
- `3.1 Risultato / Panorama` ✅ — anteprima stitch, stato elaborazione, CTA verso editor/rettifica.
- `3.2 Editor 3D mesh` ✅ — vista SceneKit della mesh, toolbar strumenti (box lavoro, lazo/pennello cancella, pennelli facce, piano-zero 3 punti, snap vertici).
- `3.4 Rettifica facciata` ✅ — raddrizza prospettiva → ortofoto piana.
- `3.5 Misura scala` ✅ — traccia un riferimento noto per fissare la scala reale (ppm).

### Fase 4 · Marcatura
- `4.1 Marcatura facciata / Zone` ✅ — sull'ortofoto: traccia zone di lavoro e aperture (finestra/porta/balcone); mostra area lorda e netta.

### Fase 5 · Preventivo
- `5.1 Preventivi / Lista` ✅ — filtro segmentato (tutti/bozza/inviato/accettato), righe con totale e stato.
- `5.2 Preventivo / Editor` ✅* — header cliente, voci di lavoro (descrizione, quantità, unità, €/u, subtotale), manodopera (ore × tariffa), totali (imponibile/IVA/totale), CTA PDF/Firma.
- `5.4 Preventivo / PDF` ✅ — anteprima documento stampabile/condivisibile.
- `5.5 Firma cliente` ✅ — area firma su schermo → accettazione.

> *`5.2` esiste come editor inline dentro `AnteprimaPreventivoView`. In Figma può restare un'unica schermata "Editor + Anteprima" oppure essere splittata. Le due 🆕 collegate qui sotto (Listino, per aggiungere voci da catalogo) la potenziano.

### Fase 6 · Anagrafiche & supporto
- `6.1 Clienti / Lista` 🆕 — anagrafica clienti, ricerca, collegamento a cantieri/preventivi.
- `6.2 Cliente / Dettaglio` 🆕 — contatti, storico cantieri e preventivi.
- `6.3 Listino materiali/prezzi` 🆕 — catalogo voci ricorrenti (descrizione, unità, prezzo); si usa per popolare le voci del preventivo.
- `6.4 Impostazioni / Profilo` 🆕 — utente, ruolo, tariffa oraria di default, IVA di default, gestione account, logout.

---

## 7. Spec delle schermate 🆕 (dettaglio per il design)

### 0.2 Login
- Sfondo `paper`. Logo/nome in alto. Card centrale con: campo Email, campo Password (toggle mostra), segmented control `Operatore | Senior`.
- CTA `BrandButton primary` "Accedi" full-width in basso. Link testuale "Password dimenticata?".
- Stati: default, errore (bordo campo `danger` + messaggio), loading (spinner nella CTA).

### 0.3 Home / Dashboard
- Header: "Ciao, ⟨nome⟩" (Display) + data.
- Riga di **3 MetricCard**: `Cantieri attivi`, `Preventivi da inviare`, `m² questo mese`.
- **Azioni rapide**: 2 bottoni grandi affiancati — "Nuovo cantiere" (primary), "Nuovo rilievo" (secondary).
- **Ultimi cantieri**: SectionHeader + 3 ListRow cantiere + "Vedi tutti".
- **Preventivi recenti**: SectionHeader + 3 ListRow preventivo.
- Empty state se tutto vuoto: illustrazione + "Crea il tuo primo cantiere".

### 6.1 Clienti / Lista
- Barra ricerca in alto. Lista di ListRow cliente (avatar iniziali su tile `navy`, nome, città, `N cantieri`).
- `+` nuovo cliente (sheet: nome, telefono, email, indirizzo, P.IVA).
- Empty state.

### 6.2 Cliente / Dettaglio
- Header: avatar + nome + contatti (telefono/email tappabili, indirizzo con mappina).
- Sezione "Cantieri" (ListRow) e "Preventivi" (ListRow con totale/stato).
- CTA "Nuovo cantiere per questo cliente".

### 6.3 Listino materiali/prezzi
- Lista raggruppabile per categoria. Ogni riga: descrizione, unità (m²/h/pz), prezzo unitario €.
- `+` nuova voce (sheet). Swipe per modifica/elimina.
- Da `5.2` un pulsante "Aggiungi da listino" apre questo catalogo in modalità selezione multipla → inserisce le voci scelte nel preventivo.

### 6.4 Impostazioni / Profilo
- Sezione Profilo: nome, ruolo (chip), email.
- Sezione Preventivi: tariffa oraria default (€/h), IVA default (%), validità default (giorni), prefisso numerazione.
- Sezione App: gestione dati/sync, informazioni, versione.
- CTA "Esci" in `danger` ghost.

---

## 8. Schermate ✅ da ricostruire (riferimento fedele al codice)

Per queste, replica esattamente layout e token del codice esistente (file tra parentesi). Il loro scopo e la struttura sono nella sezione 6.

- `CantieriListView.swift` → 1.1 · `DettaglioCantiereView.swift` → 1.4
- `CatturaARView.swift` → 2.1/2.2 · `RisultatoPanoramaView.swift` → 3.1
- `EditorMesh3DView.swift` → 3.2 · `RectifyFacadeView.swift` → 3.4 · `MeasureScaleView.swift` → 3.5
- `MarcaturaFacciataView.swift` → 4.1
- `ListaPreventiviView.swift` → 5.1 · `AnteprimaPreventivoView.swift` → 5.2 · `PDFPreventivoView.swift` → 5.4 · `FirmaClienteView.swift` → 5.5

Se serve la resa reale di una di queste, si può usare la skill `figma-swiftui` per importarla dal codice invece di ridisegnarla a mano.

---

## 9. Checklist di consegna

- [ ] Collezione `Theme` di Figma Variables (colori/tipografia/spacing/radius) — sezione 3.
- [ ] Libreria Components con varianti — sezione 4.
- [ ] Pagina `Flow` con i 21 frame collegati.
- [ ] 6 schermate 🆕 progettate (Fasi 0 e 6) + stati.
- [ ] 15 schermate ✅ ricostruite/importate.
- [ ] Varianti stato (empty/loading/error) dove indicato.
- [ ] Prototipo cliccabile del "happy path": Login → Home → Cantiere → Cattura → Editor → Marcatura → Preventivo → PDF → Firma.
- [ ] Verifica: nessun valore colore/spazio hardcoded fuori dalle Variables.

---

*Documento generato dal codice sorgente iOS (`ios/Acrobatica/`). Design system e componenti sono estratti 1:1 da `Theme.swift` e `DesignSystem/Components/`. Riferimento flusso: mappa a 7 fasi.*
