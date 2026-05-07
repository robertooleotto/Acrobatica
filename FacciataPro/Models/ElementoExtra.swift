import Foundation
import SwiftData

@Model
final class ElementoExtra {
    @Attribute(.unique) var id: UUID
    var tipoRaw: String
    var nome: String
    var parametriData: Data
    var areaMq: Double

    var facciata: Facciata?

    var tipo: TipoElementoExtra {
        get { TipoElementoExtra(rawValue: tipoRaw) ?? .balcone }
        set { tipoRaw = newValue.rawValue }
    }

    var parametri: [String: Double] {
        get { (try? JSONDecoder().decode([String: Double].self, from: parametriData)) ?? [:] }
        set { parametriData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(
        id: UUID = UUID(),
        tipo: TipoElementoExtra = .balcone,
        nome: String = "",
        parametri: [String: Double] = [:],
        areaMq: Double = 0,
        facciata: Facciata? = nil
    ) {
        self.id = id
        self.tipoRaw = tipo.rawValue
        self.nome = nome
        self.parametriData = (try? JSONEncoder().encode(parametri)) ?? Data()
        self.areaMq = areaMq
        self.facciata = facciata
    }
}
