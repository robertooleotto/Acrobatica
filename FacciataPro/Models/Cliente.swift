import Foundation
import SwiftData

@Model
final class Cliente {
    @Attribute(.unique) var id: UUID
    var tipoRaw: String
    var nome: String
    var partitaIva: String
    var codiceFiscale: String
    var telefono: String
    var email: String
    var indirizzo: String
    var cap: String
    var citta: String
    var provincia: String
    var note: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Cantiere.cliente)
    var cantieri: [Cantiere] = []

    var tipo: TipoCliente {
        get { TipoCliente(rawValue: tipoRaw) ?? .privato }
        set { tipoRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        tipo: TipoCliente = .privato,
        nome: String = "",
        partitaIva: String = "",
        codiceFiscale: String = "",
        telefono: String = "",
        email: String = "",
        indirizzo: String = "",
        cap: String = "",
        citta: String = "",
        provincia: String = "",
        note: String = ""
    ) {
        self.id = id
        self.tipoRaw = tipo.rawValue
        self.nome = nome
        self.partitaIva = partitaIva
        self.codiceFiscale = codiceFiscale
        self.telefono = telefono
        self.email = email
        self.indirizzo = indirizzo
        self.cap = cap
        self.citta = citta
        self.provincia = provincia
        self.note = note
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
