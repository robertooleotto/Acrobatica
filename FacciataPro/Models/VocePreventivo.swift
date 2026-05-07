import Foundation
import SwiftData

@Model
final class VocePreventivo {
    @Attribute(.unique) var id: UUID
    var tipoRaw: String
    var descrizione: String
    var quantita: Double
    var unitaMisura: String
    var prezzoUnitario: Double
    var totale: Double
    var ordine: Int
    var facciataId: UUID?

    var preventivo: Preventivo?

    var tipo: TipoVocePreventivo {
        get { TipoVocePreventivo(rawValue: tipoRaw) ?? .materiale }
        set { tipoRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        tipo: TipoVocePreventivo = .materiale,
        descrizione: String = "",
        quantita: Double = 0,
        unitaMisura: String = "",
        prezzoUnitario: Double = 0,
        totale: Double = 0,
        ordine: Int = 0,
        facciataId: UUID? = nil,
        preventivo: Preventivo? = nil
    ) {
        self.id = id
        self.tipoRaw = tipo.rawValue
        self.descrizione = descrizione
        self.quantita = quantita
        self.unitaMisura = unitaMisura
        self.prezzoUnitario = prezzoUnitario
        self.totale = totale
        self.ordine = ordine
        self.facciataId = facciataId
        self.preventivo = preventivo
    }
}
