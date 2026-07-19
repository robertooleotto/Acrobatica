import Foundation

/// Dati di esempio per popolare l'app (rispecchia il seed del prototipo di design).
/// Chiamato una volta all'avvio finché non c'è persistenza/back-end reale.
extension AppState {

    func caricaDemoSeInVuoto() {
        guard cantieri.isEmpty && clienti.isEmpty && preventivi.isEmpty else { return }
        caricaDemo()
    }

    func caricaDemo() {
        // ── Clienti ────────────────────────────────────────────
        clienti = [
            Cliente(nome: "Rossi Costruzioni S.r.l.", citta: "Milano",
                    telefono: "+39 02 5551 2340", email: "info@rossicostruzioni.it",
                    indirizzo: "Via Garibaldi 14, Milano", partitaIva: "IT03456780962"),
            Cliente(nome: "Bianchi Andrea", citta: "Monza",
                    telefono: "+39 339 481 2276", email: "a.bianchi@pec.it",
                    indirizzo: "Via dei Tigli 3, Monza"),
            Cliente(nome: "MV Immobiliare", citta: "Pavia",
                    telefono: "+39 0382 41 220", email: "amministrazione@mvimmobiliare.it",
                    indirizzo: "Z.I. Lotto 7, Pavia", partitaIva: "IT01998450187"),
            Cliente(nome: "Condominio Via Verdi 8", citta: "Milano",
                    telefono: "+39 02 8724 5510", email: "amm.verdi8@studiocasa.it",
                    indirizzo: "Via Verdi 8, Milano"),
        ]

        // ── Cantieri + rilievi ─────────────────────────────────
        let garibaldi = Cantiere(
            nome: "Condominio Garibaldi", cliente: "Rossi Costruzioni S.r.l.",
            indirizzo: "Via Garibaldi 14, Milano",
            rilievi: [
                Rilievo(nome: "Facciata Nord",
                        frameCatturati: [], areaLorda: 491.4, areaNetta: 408.2,
                        aperture: [Apertura(tipo: .finestra, areaM2: 2.10),
                                   Apertura(tipo: .finestra, areaM2: 2.10),
                                   Apertura(tipo: .porta, areaM2: 4.20)],
                        stato: .elaborato, orientamentoManuale: .nord),
                Rilievo(nome: "Facciata Est", areaNetta: 0, stato: .inCattura,
                        orientamentoManuale: .est),
            ],
            finitureScelte: ["Civile fine · Avorio"],
            squadra: ["Carlo Marchetti", "Luca Ferri", "Marco Riva"],
            oreProgrammate: 96)
        let villa = Cantiere(
            nome: "Villa Bianchi", cliente: "Bianchi Andrea",
            indirizzo: "Via dei Tigli 3, Monza",
            rilievi: [
                Rilievo(nome: "Facciata principale",
                        areaLorda: 212.6, areaNetta: 178.9,
                        aperture: [Apertura(tipo: .finestra, areaM2: 1.80),
                                   Apertura(tipo: .finestra, areaM2: 1.80)],
                        stato: .completato, orientamentoManuale: .sud),
            ],
            finitureScelte: ["Liscio · Bianco"],
            squadra: ["Carlo Marchetti", "Luca Ferri"],
            oreProgrammate: 48)
        let capannone = Cantiere(
            nome: "Capannone Logistica Sud", cliente: "MV Immobiliare",
            indirizzo: "Z.I. Lotto 7, Pavia")

        // Cantiere di TEST collegato alla sessione reale su Supabase (mesh pronta):
        // da qui si scarica la mesh nell'editor 3D. sessionId = fixture c1ee30e8.
        let casaTest = Cantiere(
            nome: "Casa test adriatica", cliente: "Riunione Adriatica",
            indirizzo: "Via Riunione Adriatica, Milano",
            rilievi: [
                Rilievo(nome: "Facciata (mesh OC)",
                        sessionId: "c1ee30e8-8b23-4ad4-8135-fa5d2f664a98",
                        areaNetta: 0, stato: .elaborato,
                        orientamentoManuale: .sud),
            ],
            finitureScelte: ["Liscio · Originale"],
            squadra: ["Carlo Marchetti", "Luca Ferri"],
            oreProgrammate: 40)
        cantieri = [casaTest, garibaldi, villa, capannone]

        // ── Preventivi ─────────────────────────────────────────
        preventivi = [
            Preventivo(numero: "PRV-2026-0001", clienteNome: "Rossi Costruzioni S.r.l.",
                       cantiereNome: "Condominio Garibaldi",
                       voci: [VoceLavoro(descrizione: "Tinteggiatura facciata",
                                         quantita: 408.2, unita: "m²", prezzoUnitario: 18),
                              VoceLavoro(descrizione: "Ponteggio + montaggio",
                                         quantita: 1, unita: "corpo", prezzoUnitario: 1450)],
                       manodoperaOre: 16, stato: .bozza),
            Preventivo(numero: "PRV-2026-0002", clienteNome: "Bianchi Andrea",
                       cantiereNome: "Villa Bianchi",
                       voci: [VoceLavoro(descrizione: "Idropulitura",
                                         quantita: 178.9, unita: "m²", prezzoUnitario: 6.5)],
                       manodoperaOre: 8, stato: .inviato),
            Preventivo(numero: "PRV-2025-0114", clienteNome: "MV Immobiliare",
                       cantiereNome: "Capannone Logistica Sud",
                       manodoperaOre: 40, stato: .accettato),
            Preventivo(numero: "PRV-2025-0108", clienteNome: "Condominio Via Verdi 8",
                       manodoperaOre: 12, stato: .rifiutato),
        ]

        // ── Listino ────────────────────────────────────────────
        listino = [
            VoceListino(descrizione: "Tinteggiatura facciata", unita: "m²", prezzoUnitario: 18, categoria: "Superfici"),
            VoceListino(descrizione: "Rasatura armata", unita: "m²", prezzoUnitario: 24.5, categoria: "Superfici"),
            VoceListino(descrizione: "Idropulitura", unita: "m²", prezzoUnitario: 6.5, categoria: "Superfici"),
            VoceListino(descrizione: "Trattamento contorni finestre", unita: "pz", prezzoUnitario: 45, categoria: "Aperture e contorni"),
            VoceListino(descrizione: "Sigillatura davanzali", unita: "pz", prezzoUnitario: 28, categoria: "Aperture e contorni"),
            VoceListino(descrizione: "Ponteggio + montaggio", unita: "corpo", prezzoUnitario: 1450, categoria: "Struttura e accesso"),
            VoceListino(descrizione: "Linea vita (nolo)", unita: "corpo", prezzoUnitario: 380, categoria: "Struttura e accesso"),
            VoceListino(descrizione: "Operatore su fune", unita: "h", prezzoUnitario: 35, categoria: "Manodopera"),
            VoceListino(descrizione: "Capo squadra", unita: "h", prezzoUnitario: 42, categoria: "Manodopera"),
        ]
    }
}
