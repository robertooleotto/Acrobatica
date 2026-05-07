import Foundation

enum TipoCliente: String, Codable, CaseIterable, Identifiable {
    case privato, azienda, condominio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .privato: return "Privato"
        case .azienda: return "Azienda"
        case .condominio: return "Condominio"
        }
    }
}

enum StatoCantiere: String, Codable, CaseIterable, Identifiable {
    case bozza, inviato, accettato, rifiutato, completato
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bozza: return "Bozza"
        case .inviato: return "Inviato"
        case .accettato: return "Accettato"
        case .rifiutato: return "Rifiutato"
        case .completato: return "Completato"
        }
    }
}

enum TipoElementoEscluso: String, Codable, CaseIterable, Identifiable {
    case finestra, porta, portone, vetrina, altro
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum TipoElementoExtra: String, Codable, CaseIterable, Identifiable {
    case balcone, cornicione, lesena, inferriata, sottogronda, libero
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum CategoriaProdotto: String, Codable, CaseIterable, Identifiable {
    case fissativo, intonaco_rasante, idropittura, silossanico, silicati, termico, decorativo, altro
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fissativo: return "Fissativo"
        case .intonaco_rasante: return "Intonaco rasante"
        case .idropittura: return "Idropittura"
        case .silossanico: return "Silossanico"
        case .silicati: return "Silicati"
        case .termico: return "Termico"
        case .decorativo: return "Decorativo"
        case .altro: return "Altro"
        }
    }
}

enum UnitaProdotto: String, Codable, CaseIterable, Identifiable {
    case litro, kg, sacco
    var id: String { rawValue }
    var simbolo: String {
        switch self {
        case .litro: return "L"
        case .kg: return "kg"
        case .sacco: return "sacco"
        }
    }
}

enum CategoriaCiclo: String, Codable, CaseIterable, Identifiable {
    case esterno, interno, speciale
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum UnitaVoceAccessoria: String, Codable, CaseIterable, Identifiable {
    case a_corpo, a_giornata, mq, metro_lineare
    var id: String { rawValue }
    var label: String {
        switch self {
        case .a_corpo: return "A corpo"
        case .a_giornata: return "A giornata"
        case .mq: return "m²"
        case .metro_lineare: return "ml"
        }
    }
}

enum TipoVocePreventivo: String, Codable, CaseIterable {
    case materiale, manodopera, accessoria
}

struct PoligonoJSON: Codable, Hashable {
    var punti: [PuntoJSON]
}

struct PuntoJSON: Codable, Hashable {
    var x: Double
    var y: Double
}
