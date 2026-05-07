import Foundation
import SwiftData

@Model
final class Cantiere {
    @Attribute(.unique) var id: UUID
    var nome: String
    var indirizzoCantiere: String
    var coordinateLat: Double?
    var coordinateLng: Double?
    var statoRaw: String
    var note: String
    var createdAt: Date
    var updatedAt: Date

    var cliente: Cliente?

    @Relationship(deleteRule: .cascade, inverse: \Facciata.cantiere)
    var facciate: [Facciata] = []

    @Relationship(deleteRule: .cascade, inverse: \Preventivo.cantiere)
    var preventivi: [Preventivo] = []

    var stato: StatoCantiere {
        get { StatoCantiere(rawValue: statoRaw) ?? .bozza }
        set { statoRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        nome: String = "",
        indirizzoCantiere: String = "",
        coordinateLat: Double? = nil,
        coordinateLng: Double? = nil,
        stato: StatoCantiere = .bozza,
        note: String = "",
        cliente: Cliente? = nil
    ) {
        self.id = id
        self.nome = nome
        self.indirizzoCantiere = indirizzoCantiere
        self.coordinateLat = coordinateLat
        self.coordinateLng = coordinateLng
        self.statoRaw = stato.rawValue
        self.note = note
        self.cliente = cliente
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
