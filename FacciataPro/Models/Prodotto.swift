import Foundation
import SwiftData

@Model
final class Prodotto {
    @Attribute(.unique) var id: UUID
    var nomeCommerciale: String
    var brand: String
    var categoriaRaw: String
    var unitaRaw: String
    var formatoVendita: Double
    var prezzoUnitario: Double
    var resaMqPerUnita: Double
    var coefficienteAbbondamento: Double
    var maniConsigliate: Int
    var note: String
    var createdAt: Date
    var updatedAt: Date

    var categoria: CategoriaProdotto {
        get { CategoriaProdotto(rawValue: categoriaRaw) ?? .altro }
        set { categoriaRaw = newValue.rawValue }
    }

    var unita: UnitaProdotto {
        get { UnitaProdotto(rawValue: unitaRaw) ?? .litro }
        set { unitaRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        nomeCommerciale: String = "",
        brand: String = "",
        categoria: CategoriaProdotto = .altro,
        unita: UnitaProdotto = .litro,
        formatoVendita: Double = 1,
        prezzoUnitario: Double = 0,
        resaMqPerUnita: Double = 0,
        coefficienteAbbondamento: Double = 1.15,
        maniConsigliate: Int = 2,
        note: String = ""
    ) {
        self.id = id
        self.nomeCommerciale = nomeCommerciale
        self.brand = brand
        self.categoriaRaw = categoria.rawValue
        self.unitaRaw = unita.rawValue
        self.formatoVendita = formatoVendita
        self.prezzoUnitario = prezzoUnitario
        self.resaMqPerUnita = resaMqPerUnita
        self.coefficienteAbbondamento = coefficienteAbbondamento
        self.maniConsigliate = maniConsigliate
        self.note = note
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
