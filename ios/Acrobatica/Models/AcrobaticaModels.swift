import Foundation
import SwiftUI

// MARK: - Cantiere (= job site)

final class Cantiere: ObservableObject, Identifiable {
    let id: UUID
    @Published var nome: String
    @Published var cliente: String
    @Published var indirizzo: String
    @Published var dataCreazione: Date
    @Published var rilievi: [Rilievo]

    init(id: UUID = UUID(),
         nome: String,
         cliente: String,
         indirizzo: String = "",
         dataCreazione: Date = .now,
         rilievi: [Rilievo] = []) {
        self.id = id
        self.nome = nome
        self.cliente = cliente
        self.indirizzo = indirizzo
        self.dataCreazione = dataCreazione
        self.rilievi = rilievi
    }
}

// MARK: - Rilievo (= survey = facciata) — wraps i CapturedFacadePhoto

final class Rilievo: ObservableObject, Identifiable {
    let id: UUID
    @Published var nome: String
    @Published var sessionId: String?           // id Supabase facade_session
    @Published var frameCatturati: [CapturedFacadePhoto]
    @Published var panoramaUrl: URL?            // download dello stitch
    @Published var areaLorda: Double            // m²
    @Published var areaNetta: Double            // m² al netto aperture
    @Published var aperture: [Apertura]
    @Published var stato: Stato
    @Published var creatoIl: Date

    enum Stato: String, Codable {
        case bozza      = "Bozza"
        case inCattura  = "In cattura"
        case elaborato  = "Elaborato"
        case completato = "Completato"
    }

    init(id: UUID = UUID(),
         nome: String = "Facciata",
         sessionId: String? = nil,
         frameCatturati: [CapturedFacadePhoto] = [],
         panoramaUrl: URL? = nil,
         areaLorda: Double = 0,
         areaNetta: Double = 0,
         aperture: [Apertura] = [],
         stato: Stato = .bozza,
         creatoIl: Date = .now) {
        self.id = id
        self.nome = nome
        self.sessionId = sessionId
        self.frameCatturati = frameCatturati
        self.panoramaUrl = panoramaUrl
        self.areaLorda = areaLorda
        self.areaNetta = areaNetta
        self.aperture = aperture
        self.stato = stato
        self.creatoIl = creatoIl
    }

    func aggiungiFrame(_ p: CapturedFacadePhoto) {
        frameCatturati.append(p)
    }
    func rimuoviUltimoFrame() {
        _ = frameCatturati.popLast()
    }
}

// MARK: - Apertura (finestra/porta/balcone sulla facciata)

struct Apertura: Identifiable, Codable, Hashable {
    enum Tipo: String, Codable, CaseIterable { case finestra, porta, balcone, altro }
    let id: UUID
    var tipo: Tipo
    var origineX: Double         // 0…1 normalizzato sul panorama rettificato
    var origineY: Double
    var larghezza: Double        // 0…1
    var altezza: Double
    var areaM2: Double?

    init(id: UUID = UUID(),
         tipo: Tipo = .finestra,
         origineX: Double = 0, origineY: Double = 0,
         larghezza: Double = 0.1, altezza: Double = 0.15,
         areaM2: Double? = nil) {
        self.id = id; self.tipo = tipo
        self.origineX = origineX; self.origineY = origineY
        self.larghezza = larghezza; self.altezza = altezza
        self.areaM2 = areaM2
    }
}

// MARK: - Preventivo

final class Preventivo: ObservableObject, Identifiable {
    let id: UUID
    @Published var numero: String
    @Published var clienteNome: String
    @Published var cantiereNome: String
    @Published var data: Date
    @Published var validitaGiorni: Int
    @Published var voci: [VoceLavoro]
    @Published var manodoperaOre: Double
    @Published var tariffaOraria: Double
    @Published var scontoPct: Double
    @Published var ivaPct: Double
    @Published var stato: Stato
    @Published var rilievoId: UUID?

    enum Stato: String, Codable {
        case bozza, inviato, accettato, rifiutato, scaduto
    }

    init(id: UUID = UUID(),
         numero: String,
         clienteNome: String,
         cantiereNome: String = "",
         data: Date = .now,
         validitaGiorni: Int = 30,
         voci: [VoceLavoro] = [],
         manodoperaOre: Double = 0,
         tariffaOraria: Double = 35,
         scontoPct: Double = 0,
         ivaPct: Double = 22,
         stato: Stato = .bozza,
         rilievoId: UUID? = nil) {
        self.id = id; self.numero = numero
        self.clienteNome = clienteNome; self.cantiereNome = cantiereNome
        self.data = data; self.validitaGiorni = validitaGiorni
        self.voci = voci
        self.manodoperaOre = manodoperaOre; self.tariffaOraria = tariffaOraria
        self.scontoPct = scontoPct; self.ivaPct = ivaPct
        self.stato = stato
        self.rilievoId = rilievoId
    }

    var imponibile: Double {
        let voci = voci.reduce(0.0) { $0 + $1.subtotale }
        let manodopera = manodoperaOre * tariffaOraria
        let lordo = voci + manodopera
        return lordo * (1 - scontoPct/100)
    }
    var iva: Double { imponibile * ivaPct / 100 }
    var totale: Double { imponibile + iva }
}

extension Preventivo: Hashable {
    static func == (lhs: Preventivo, rhs: Preventivo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct VoceLavoro: Identifiable, Codable, Hashable {
    let id: UUID
    var descrizione: String
    var quantita: Double         // es. m²
    var unita: String            // es. "m²", "h", "pz"
    var prezzoUnitario: Double   // €
    var materialeNome: String?

    init(id: UUID = UUID(),
         descrizione: String,
         quantita: Double = 1,
         unita: String = "m²",
         prezzoUnitario: Double = 0,
         materialeNome: String? = nil) {
        self.id = id; self.descrizione = descrizione
        self.quantita = quantita; self.unita = unita
        self.prezzoUnitario = prezzoUnitario
        self.materialeNome = materialeNome
    }

    var subtotale: Double { quantita * prezzoUnitario }
}

// MARK: - AppState in-memory (lista cantieri + preventivi per ora locali)

final class AppState: ObservableObject {
    @Published var cantieri: [Cantiere] = []
    @Published var preventivi: [Preventivo] = []
    /// Ruolo utente loggato (multi-utente futuro). Default operatore.
    @Published var ruoloUtente: Ruolo = .operatore

    enum Ruolo: String, Codable { case operatore, senior }

    /// Genera un id-preventivo progressivo umano (PRV-YYYY-NNNN).
    func nuovoNumeroPreventivo() -> String {
        let year = Calendar.current.component(.year, from: .now)
        let n = preventivi.filter { $0.numero.contains("\(year)") }.count + 1
        return String(format: "PRV-%04d-%04d", year, n)
    }
}
