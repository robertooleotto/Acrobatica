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
    @Published var clienti: [Cliente] = []
    @Published var listino: [VoceListino] = []

    /// Ruolo utente loggato (multi-utente futuro). Default operatore.
    @Published var ruoloUtente: Ruolo = .operatore

    // ─── Profilo / impostazioni ────────────────────────────────
    @Published var utenteNome  = "Carlo Marchetti"
    @Published var utenteEmail = "carlo@impresaedile.it"
    @Published var tariffaOrariaDefault: Double = 35
    @Published var ivaDefault: Double = 22
    @Published var validitaDefault: Int = 30
    @Published var prefissoPreventivo = "PRV"

    enum Ruolo: String, Codable { case operatore, senior }

    /// Genera un id-preventivo progressivo umano (PRV-YYYY-NNNN).
    func nuovoNumeroPreventivo() -> String {
        let year = Calendar.current.component(.year, from: .now)
        let n = preventivi.filter { $0.numero.contains("\(year)") }.count + 1
        return String(format: "\(prefissoPreventivo)-%04d-%04d", year, n)
    }

    // ─── Collegamenti cliente ↔ cantieri/preventivi (per nome) ──
    func cantieri(di cliente: Cliente) -> [Cantiere] {
        cantieri.filter { $0.cliente == cliente.nome }
    }
    func preventivi(di cliente: Cliente) -> [Preventivo] {
        preventivi.filter { $0.clienteNome == cliente.nome }
    }

    /// m² netti dei rilievi elaborati (KPI dashboard).
    var metriTotali: Double {
        cantieri.flatMap { $0.rilievi }.reduce(0) { $0 + $1.areaNetta }
    }

    /// Listino raggruppato per categoria, ordine di prima apparizione.
    var listinoPerCategoria: [(categoria: String, voci: [VoceListino])] {
        var ordine: [String] = []
        var mappa: [String: [VoceListino]] = [:]
        for v in listino {
            if mappa[v.categoria] == nil { ordine.append(v.categoria) }
            mappa[v.categoria, default: []].append(v)
        }
        return ordine.map { ($0, mappa[$0] ?? []) }
    }
}

// MARK: - Cliente (anagrafica)

final class Cliente: ObservableObject, Identifiable {
    let id: UUID
    @Published var nome: String
    @Published var citta: String
    @Published var telefono: String
    @Published var email: String
    @Published var indirizzo: String
    @Published var partitaIva: String

    init(id: UUID = UUID(),
         nome: String,
         citta: String = "",
         telefono: String = "",
         email: String = "",
         indirizzo: String = "",
         partitaIva: String = "—") {
        self.id = id
        self.nome = nome
        self.citta = citta
        self.telefono = telefono
        self.email = email
        self.indirizzo = indirizzo
        self.partitaIva = partitaIva
    }

    /// Iniziali (max 2) per l'avatar.
    var iniziali: String {
        nome.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}

extension Cliente: Hashable {
    static func == (l: Cliente, r: Cliente) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - VoceListino (catalogo prezzi)

struct VoceListino: Identifiable, Codable, Hashable {
    let id: UUID
    var descrizione: String
    var unita: String            // es. "m²", "h", "pz", "corpo"
    var prezzoUnitario: Double
    var categoria: String

    init(id: UUID = UUID(),
         descrizione: String,
         unita: String = "m²",
         prezzoUnitario: Double = 0,
         categoria: String = "Generale") {
        self.id = id
        self.descrizione = descrizione
        self.unita = unita
        self.prezzoUnitario = prezzoUnitario
        self.categoria = categoria
    }
}
