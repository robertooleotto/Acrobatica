import SwiftUI

// MARK: – Tipo di zona

/// Tipo di zona marcabile sull'ortofoto della facciata.
/// I rawValue sono serializzati nel JSON e DEVONO restare compatibili
/// con la pipeline Python a valle ("esclusa|da_rifare|misurabile|nota|lineare").
enum TipoZona: String, Codable, CaseIterable, Identifiable {
    case esclusa
    case daRifare = "da_rifare"
    case misurabile
    case nota
    case lineare

    var id: String { rawValue }

    var etichetta: String {
        switch self {
        case .esclusa:    return "Esclusa"
        case .daRifare:   return "Da rifare"
        case .misurabile: return "Misurabile"
        case .nota:       return "Nota"
        case .lineare:    return "Lineare"
        }
    }

    /// Colore esadecimale serializzato nel JSON (#RRGGBB).
    var coloreHex: String {
        switch self {
        case .esclusa:    return "#D9342B"   // rosso
        case .daRifare:   return "#F5C518"   // giallo
        case .misurabile: return "#1FA463"   // verde
        case .nota:       return "#3B9DD2"   // azzurro
        case .lineare:    return "#C66BD6"   // viola
        }
    }

    var colore: Color { Color(hexString: coloreHex) }

    var icona: String {
        switch self {
        case .esclusa:    return "nosign"
        case .daRifare:   return "arrow.triangle.2.circlepath"
        case .misurabile: return "checkmark.seal"
        case .nota:       return "note.text"
        case .lineare:    return "scribble"
        }
    }

    /// Le zone escluse si disegnano col tratteggio diagonale (stile "non misurabile").
    var tratteggioDiagonale: Bool { self == .esclusa }

    /// Polilinea APERTA misurata in metri lineari (ringhiere, cornicioni):
    /// niente area, niente fill; perimetro_m = lunghezza della linea.
    var isLineare: Bool { self == .lineare }
}

// MARK: – Zona

/// Poligono marcato dal rilevatore sull'ortofoto. Coordinate in PIXEL
/// dell'ortofoto (origine in alto a sinistra, come in OpenCV/PIL).
/// Area/perimetro sono in unità metriche, calcolati con la scala ppm (px/m).
struct ZonaFacciata: Identifiable, Equatable {
    let id: UUID
    var nome: String
    var tipo: TipoZona
    var visibile: Bool
    var puntiPx: [CGPoint]
    var areaM2: Double
    var perimetroM: Double

    init(id: UUID = UUID(),
         nome: String,
         tipo: TipoZona,
         visibile: Bool = true,
         puntiPx: [CGPoint],
         ppm: Double) {
        self.id = id
        self.nome = nome
        self.tipo = tipo
        self.visibile = visibile
        self.puntiPx = puntiPx
        self.areaM2 = 0
        self.perimetroM = 0
        aggiornaMetriche(ppm: ppm)
    }

    /// Ricalcola area (shoelace) e perimetro a partire dai punti in px.
    /// Per il tipo lineare: area 0 e perimetro = lunghezza della polilinea aperta.
    mutating func aggiornaMetriche(ppm: Double) {
        guard ppm > 0 else { areaM2 = 0; perimetroM = 0; return }
        if tipo.isLineare {
            areaM2 = 0
            perimetroM = Self.lunghezzaApertaPx(puntiPx) / ppm
        } else {
            areaM2 = Self.areaPx2(puntiPx) / (ppm * ppm)
            perimetroM = Self.perimetroPx(puntiPx) / ppm
        }
    }

    /// Area del poligono in px² (formula shoelace, valore assoluto).
    static func areaPx2(_ punti: [CGPoint]) -> Double {
        guard punti.count >= 3 else { return 0 }
        var somma = 0.0
        for i in 0..<punti.count {
            let a = punti[i]
            let b = punti[(i + 1) % punti.count]
            somma += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return abs(somma) / 2
    }

    /// Perimetro del poligono chiuso in px.
    static func perimetroPx(_ punti: [CGPoint]) -> Double {
        guard punti.count >= 2 else { return 0 }
        var somma = 0.0
        for i in 0..<punti.count {
            let a = punti[i]
            let b = punti[(i + 1) % punti.count]
            somma += hypot(Double(b.x - a.x), Double(b.y - a.y))
        }
        return somma
    }

    /// Lunghezza della polilinea APERTA in px (per il tipo lineare).
    static func lunghezzaApertaPx(_ punti: [CGPoint]) -> Double {
        guard punti.count >= 2 else { return 0 }
        var somma = 0.0
        for i in 0..<(punti.count - 1) {
            somma += hypot(Double(punti[i + 1].x - punti[i].x),
                           Double(punti[i + 1].y - punti[i].y))
        }
        return somma
    }

    /// Test punto-in-poligono (ray casting), coordinate in px immagine.
    /// Per le linee: vicinanza a uno dei segmenti (tolleranza in px).
    func contiene(_ p: CGPoint, tolleranzaLineaPx: CGFloat = 12) -> Bool {
        if tipo.isLineare {
            guard puntiPx.count >= 2 else { return false }
            for i in 0..<(puntiPx.count - 1) {
                if Self.distanzaDaSegmento(p, puntiPx[i], puntiPx[i + 1]) <= tolleranzaLineaPx {
                    return true
                }
            }
            return false
        }
        guard puntiPx.count >= 3 else { return false }
        var dentro = false
        var j = puntiPx.count - 1
        for i in 0..<puntiPx.count {
            let a = puntiPx[i], b = puntiPx[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                dentro.toggle()
            }
            j = i
        }
        return dentro
    }

    /// Distanza punto-segmento in px (hit test delle linee).
    static func distanzaDaSegmento(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    /// Baricentro (media dei vertici) — usato per posizionare l'etichetta.
    var baricentro: CGPoint {
        guard !puntiPx.isEmpty else { return .zero }
        let sx = puntiPx.reduce(0) { $0 + $1.x }
        let sy = puntiPx.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(puntiPx.count), y: sy / CGFloat(puntiPx.count))
    }
}

// MARK: – Codable (schema JSON compatibile con la pipeline Python)

extension ZonaFacciata: Codable {
    enum CodingKeys: String, CodingKey {
        case nome, tipo, visibile, colore
        case puntiPx    = "punti_px"
        case areaM2     = "area_m2"
        case perimetroM = "perimetro_m"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        nome = try c.decode(String.self, forKey: .nome)
        tipo = try c.decode(TipoZona.self, forKey: .tipo)
        visibile = try c.decodeIfPresent(Bool.self, forKey: .visibile) ?? true
        let grezzi = try c.decode([[Double]].self, forKey: .puntiPx)
        puntiPx = grezzi.compactMap { $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        areaM2 = try c.decodeIfPresent(Double.self, forKey: .areaM2) ?? 0
        perimetroM = try c.decodeIfPresent(Double.self, forKey: .perimetroM) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nome, forKey: .nome)
        try c.encode(tipo, forKey: .tipo)
        try c.encode(visibile, forKey: .visibile)
        try c.encode(tipo.coloreHex, forKey: .colore)
        try c.encode(puntiPx.map { [Double($0.x), Double($0.y)] }, forKey: .puntiPx)
        try c.encode(areaM2, forKey: .areaM2)
        try c.encode(perimetroM, forKey: .perimetroM)
    }
}

// MARK: – Documento di marcatura

/// Documento completo serializzato in JSON:
/// {"versione":1,"ppm":110,"larghezza_px":2268,"altezza_px":1936,"zone":[...]}
struct MarcaturaFacciata: Codable {
    var versione: Int = 1
    var ppm: Double
    var larghezzaPx: Int
    var altezzaPx: Int
    var zone: [ZonaFacciata]

    enum CodingKeys: String, CodingKey {
        case versione, ppm, zone
        case larghezzaPx = "larghezza_px"
        case altezzaPx   = "altezza_px"
    }

    func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    static func da(jsonData: Data) throws -> MarcaturaFacciata {
        try JSONDecoder().decode(MarcaturaFacciata.self, from: jsonData)
    }
}

// MARK: – Helper Color("#RRGGBB")

extension Color {
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0xFFFFFF
        self.init(hex: v)
    }
}
