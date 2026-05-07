# FacciataPro — Briefing Tecnico per Claude Code

> **Documento di specifica completo per lo sviluppo dell'app FacciataPro.**
> Versione MVP-first: implementare prima la parte core, poi estendere.

---

## 1. COSA È FACCIATAPRO

FacciataPro è un'**app mobile nativa (iOS + Android)** per imbianchini e ditte edili che permette di:

1. Scattare una foto di una facciata
2. Rilevarne le dimensioni a partire da un riferimento noto (porta, finestra)
3. Calcolare la superficie netta (escludendo infissi)
4. Simulare l'applicazione di diverse tinte di intonaco/pittura (effetto prima/dopo)
5. Calcolare il costo della ristrutturazione usando un database di prodotti
6. Generare un PDF di preventivo professionale, firmabile dal cliente

**Target utente:** imbianchini autonomi, ditte edili piccole-medie. Persone che lavorano in cantiere, con mani sporche, sole in faccia, fretta. **L'app deve essere semplice, veloce, e funzionare offline**.

**Modello di business:** white-label per produttori di pittura (Sikkens, San Marco, Caparol, ecc.) — quindi l'architettura deve essere pensata per essere brandizzabile.

---

## 2. STACK TECNOLOGICO

### Mobile
- **iOS**: Swift + SwiftUI (target iOS 16+)
- **Android**: Kotlin + Jetpack Compose (target API 26+)
- **NO React Native, NO Flutter**: serve nativo per fotocamera, Vision/ML Kit, rendering grafico

### Backend
- **Linguaggio**: Node.js + TypeScript (Fastify o NestJS) **OPPURE** Python (FastAPI)
- **Database**: PostgreSQL (Supabase è perfetto come BaaS)
- **Storage immagini**: S3-compatible (Supabase Storage o AWS S3)
- **Auth**: Supabase Auth oppure JWT custom

### Computer vision (sul device, NON server-side)
- **iOS**: framework Vision (rilevamento rettangoli, OCR), Core Image (rettifica prospettica), CoreML per segmentazione
- **Android**: ML Kit (rettangoli, OCR), OpenCV per omografia, TensorFlow Lite per segmentazione

### PDF generation
- **iOS**: PDFKit nativo
- **Android**: Android PDF API o iText
- **Backend (alternativa)**: puppeteer + template HTML

---

## 3. ARCHITETTURA GENERALE

**Principio architetturale chiave**: **offline-first**. L'app deve funzionare al 100% senza internet. Sync con cloud opportunistico, in background, quando c'è rete.

**La logica di calcolo del preventivo va centralizzata**: scrivila come libreria condivisa (es. una `pricing-engine` ben isolata in entrambi i client) o come API server-side. Una sola fonte di verità.

---

## 4. MODELLO DATI

Schema essenziale delle entità. I tipi indicati sono per PostgreSQL ma adattabili.

### `azienda` (configurazione utente)
- `id` UUID PK
- `ragione_sociale` TEXT
- `partita_iva` TEXT
- `codice_fiscale` TEXT
- `indirizzo`, `cap`, `citta`, `provincia` TEXT
- `telefono`, `email`, `pec` TEXT
- `iban` TEXT
- `logo_url` TEXT
- `iva_default` DECIMAL (es. 10.0 o 22.0)
- `created_at`, `updated_at` TIMESTAMP

### `cliente`
- `id` UUID PK
- `azienda_id` FK → azienda
- `tipo` ENUM('privato', 'azienda', 'condominio')
- `nome` TEXT
- `partita_iva`, `codice_fiscale` TEXT (opzionali)
- `telefono`, `email` TEXT
- `indirizzo`, `cap`, `citta`, `provincia` TEXT
- `note` TEXT

### `cantiere`
- `id`, `azienda_id`, `cliente_id`
- `nome`, `indirizzo_cantiere`
- `coordinate_lat`, `coordinate_lng` (opzionali)
- `stato` ENUM('bozza', 'inviato', 'accettato', 'rifiutato', 'completato')
- `note`

### `facciata`
- `cantiere_id`
- `nome` (es. "Facciata Nord")
- `foto_originale_url`, `foto_raddrizzata_url`
- `homography_matrix` JSON
- `pixel_per_cm` DECIMAL
- `larghezza_m`, `altezza_m`
- `superficie_lorda_mq`, `superficie_netta_mq`

### `elemento_escluso` (infissi)
- `facciata_id`
- `tipo` ENUM('finestra', 'porta', 'portone', 'vetrina', 'altro')
- `poligono` JSON
- `area_mq`, `nome`

### `elemento_extra` (balconi, cornicioni)
- `facciata_id`
- `tipo` ENUM('balcone', 'cornicione', 'lesena', 'inferriata', 'sottogronda', 'libero')
- `parametri` JSON
- `area_mq`, `nome`

### `simulazione_tinta`
- `facciata_id`
- `nome`
- `zone` JSON (array di {poligono, colore_hex, ciclo_id?})
- `foto_simulata_url`
- `is_selected` BOOL

### `prodotto`
- `azienda_id`
- `nome_commerciale`, `brand`
- `categoria` ENUM('fissativo', 'intonaco_rasante', 'idropittura', 'silossanico', 'silicati', 'termico', 'decorativo', 'altro')
- `unita` ENUM('litro', 'kg', 'sacco')
- `formato_vendita` DECIMAL
- `prezzo_unitario` DECIMAL (€/litro o €/kg)
- `resa_mq_per_unita` DECIMAL
- `coefficiente_abbondamento` DECIMAL (default 1.15)
- `mani_consigliate` INT (default 2)

### `ciclo_lavorazione`
- `azienda_id`
- `nome`, `categoria` ENUM('esterno', 'interno', 'speciale')
- `manodopera_eur_mq` DECIMAL

### `step_ciclo`
- `ciclo_id`, `prodotto_id`
- `ordine` INT, `mani` INT

### `voce_accessoria`
- `azienda_id`, `nome`
- `unita` ENUM('a_corpo', 'a_giornata', 'mq', 'metro_lineare')
- `prezzo`

### `preventivo`
- `cantiere_id`, `numero`, `data_emissione`
- `validita_giorni` (default 30)
- `condizioni_pagamento`, `tempi_consegna`, `note`
- `mostra_dettaglio_materiali`, `mostra_prezzi_per_facciata` BOOL
- `margine_globale_perc`, `iva_perc` DECIMAL
- `imponibile`, `iva_eur`, `totale` DECIMAL
- `pdf_url`, `firma_cliente_url`, `firma_data`

### `voce_preventivo`
- `preventivo_id`, `facciata_id` (NULL per voci globali)
- `tipo` ENUM('materiale', 'manodopera', 'accessoria')
- `descrizione`, `quantita`, `unita_misura`
- `prezzo_unitario`, `totale`, `ordine`

---

## 5. LOGICA DI CALCOLO PREVENTIVO

```
function calcolaPreventivoFacciata(facciata, ciclo, voci_accessorie, params):
    superficie_netta = facciata.superficie_lorda
                     - sum(elementi_esclusi.area)
                     + sum(elementi_extra.area)

    voci = []

    // MATERIALI
    for step in ciclo.steps:
        prodotto = step.prodotto
        mani = step.mani
        qty_teorica = (superficie_netta * mani) / prodotto.resa_mq_per_unita
        qty_con_abbondamento = qty_teorica * prodotto.coefficiente_abbondamento
        n_confezioni = ceil(qty_con_abbondamento / prodotto.formato_vendita)
        costo = n_confezioni * (prodotto.formato_vendita * prodotto.prezzo_unitario)
        voci.push(...)

    // MANODOPERA: superficie_netta * ciclo.manodopera_eur_mq
    // ACCESSORIE: somma diretta voci

    subtotale = sum(voci.totale)
    con_margine = subtotale * (1 + margine_globale_perc / 100)
    iva = con_margine * (iva_perc / 100)
    totale = con_margine + iva
```

**Punti critici:**
1. Arrotondamento verso l'alto al formato di vendita (mai mezze unità)
2. Coefficiente di abbondamento per prodotto (default 1.15)
3. Manodopera per mq netti, non lordi
4. Voci accessorie a corpo non si moltiplicano per superficie
5. IVA si applica solo alla fine, dopo il margine

---

## 6. COMPUTER VISION PIPELINE

1. **Cattura foto**: camera fullscreen + overlay (griglia, livello, suggerimenti)
2. **Rilevamento angoli**: VNDetectRectanglesRequest (iOS), ML Kit (Android), confidence < 0.7 → manuale
3. **Rettifica prospettica**: 4 punti → omografia → CIPerspectiveCorrection / OpenCV warpPerspective
4. **Calibrazione dimensionale**: segmento + cm → pixel_per_cm
5. **Selezione infissi**: MVP manuale (poligoni a dito), V2 SAM/Vision auto
6. **Simulazione colore**: blending multiply preservando luminanza (canale Y di YCbCr)

---

## 7. SCHERMATE DELL'APP

(elenco completo, vedi briefing originale per dettagli ⭐ MVP)

- **Sezione 1 — Onboarding**: 1.1 Welcome, 1.2 Setup ditta
- **Sezione 2 — Cantieri**: 2.1 Lista, 2.2 Nuovo, 2.3 Dettaglio
- **Sezione 3 — Sopralluogo (7 step)**: 3.1 Foto, 3.2 Raddrizzamento, 3.3 Calibrazione, 3.4 Infissi, 3.4b Extra, 3.5 Tinte, 3.6 Ciclo, 3.7 Riepilogo
- **Sezione 4 — Preventivo**: 4.1 Anteprima, 4.2 PDF, 4.3 Firma
- **Sezione 5 — Listino**: 5.1 Home, 5.2 Prodotti, 5.2b Edit, 5.3 Cicli, 5.3b Edit, 5.4 Voci accessorie
- **Sezione 6 — Clienti**: 6.1 Lista, 6.2 Edit
- **Sezione 7 — Profilo**: 7.1 Home, 7.2 PDF custom, 7.3 Default

---

## 8. ROADMAP DI IMPLEMENTAZIONE

- **FASE 1 — FOUNDATION** (sett. 1-2): setup, modello dati, onboarding, cantieri vuoti, profilo
- **FASE 2 — LISTINO** (sett. 3-4): tutta la sezione 5 + dati seed precaricati
- **FASE 3 — SOPRALLUOGO BASE** (sett. 5-7): foto + raddrizzamento manuale + calibrazione + infissi + riepilogo
- **FASE 4 — SIMULAZIONE COLORE** (sett. 8-9): palette + blending luminance preservation
- **FASE 5 — PREVENTIVO E PDF** (sett. 10-11): pricing engine + PDF
- **FASE 6 — POLISH** (sett. 12): firma, multi-facciata, extra, bug fix
- **FASE 7 — V2** (post-MVP): auto-detect, SAM, sync cloud, backend completo

---

## 9. PRINCIPI UX

1. Offline-first
2. Salvataggio automatico
3. Tap target ≥ 56×56 pt
4. Numeri sempre visibili
5. Una decisione per schermata
6. Override manuale sempre disponibile
7. Confidence < 0.7 = chiedi all'utente
8. Onboarding minimo
9. Linguaggio professionale italiano
10. Niente animazioni gratuite

---

## 10. CATALOGO INIZIALE PRECARICATO

### Prodotti seed (10)
| Nome | Brand | Categoria | Formato | €/u | Resa | Mani |
|------|-------|-----------|---------|-----|------|------|
| Fissativo universale | Generico | fissativo | 10L | 6,00 | 8 | 1 |
| Idropittura standard | Generico | idropittura | 14L | 4,50 | 6 | 2 |
| Idropittura premium | Generico | idropittura | 14L | 8,00 | 7 | 2 |
| Silossanico esterno | Generico | silossanico | 14L | 12,00 | 7 | 2 |
| Silossanico premium | Generico | silossanico | 14L | 18,00 | 7 | 2 |
| Pittura ai silicati | Generico | silicati | 14L | 22,00 | 7 | 2 |
| Rasante per facciata | Generico | intonaco_rasante | 25kg | 18,00 | 5 | 1 |
| Pittura termica | Generico | termico | 12L | 35,00 | 6 | 2 |
| Decorativo eff. sabbia | Generico | decorativo | 14L | 28,00 | 5 | 1 |
| Primer minerale | Generico | fissativo | 10L | 14,00 | 8 | 1 |

### Cicli seed (3)
- Ciclo economico: Fissativo (1m) + Idropittura standard (2m) — 12 €/mq
- Ciclo silossanico standard: Fissativo (1m) + Silossanico esterno (2m) — 18 €/mq
- Ciclo silossanico premium: Primer minerale (1m) + Silossanico premium (2m) — 22 €/mq

### Voci accessorie seed (4)
- Ponteggio (a_corpo) — 800 €
- Protezioni serramenti (a_corpo) — 150 €
- Smaltimento rifiuti edili (a_corpo) — 200 €
- Trasferta (a_giornata) — 80 €

---

## 14. NOTE FINALI

- Non ottimizzare prematuramente
- Test sui calcoli sono obbligatori
- Non implementare il backend prima del mobile
- Testare in cantiere reale
