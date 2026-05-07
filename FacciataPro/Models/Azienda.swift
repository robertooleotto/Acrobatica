import Foundation
import SwiftData

@Model
final class Azienda {
    @Attribute(.unique) var id: UUID
    var ragioneSociale: String
    var partitaIva: String
    var codiceFiscale: String
    var indirizzo: String
    var cap: String
    var citta: String
    var provincia: String
    var telefono: String
    var email: String
    var pec: String
    var iban: String
    var logoData: Data?
    var ivaDefault: Decimal
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        ragioneSociale: String = "",
        partitaIva: String = "",
        codiceFiscale: String = "",
        indirizzo: String = "",
        cap: String = "",
        citta: String = "",
        provincia: String = "",
        telefono: String = "",
        email: String = "",
        pec: String = "",
        iban: String = "",
        logoData: Data? = nil,
        ivaDefault: Decimal = 22.0
    ) {
        self.id = id
        self.ragioneSociale = ragioneSociale
        self.partitaIva = partitaIva
        self.codiceFiscale = codiceFiscale
        self.indirizzo = indirizzo
        self.cap = cap
        self.citta = citta
        self.provincia = provincia
        self.telefono = telefono
        self.email = email
        self.pec = pec
        self.iban = iban
        self.logoData = logoData
        self.ivaDefault = ivaDefault
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
