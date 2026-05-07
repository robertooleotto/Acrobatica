import Foundation
import SwiftData

@Model
final class VoceAccessoria {
    @Attribute(.unique) var id: UUID
    var nome: String
    var unitaRaw: String
    var prezzo: Double
    var createdAt: Date
    var updatedAt: Date

    var unita: UnitaVoceAccessoria {
        get { UnitaVoceAccessoria(rawValue: unitaRaw) ?? .a_corpo }
        set { unitaRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        nome: String = "",
        unita: UnitaVoceAccessoria = .a_corpo,
        prezzo: Double = 0
    ) {
        self.id = id
        self.nome = nome
        self.unitaRaw = unita.rawValue
        self.prezzo = prezzo
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
