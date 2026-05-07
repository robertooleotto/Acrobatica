import Foundation
import SwiftData

@Model
final class Preventivo {
    @Attribute(.unique) var id: UUID
    var numero: String
    var dataEmissione: Date
    var validitaGiorni: Int
    var condizioniPagamento: String
    var tempiConsegna: String
    var note: String
    var mostraDettaglioMateriali: Bool
    var mostraPrezziPerFacciata: Bool
    var margineGlobalePerc: Double
    var ivaPerc: Double
    var imponibile: Double
    var ivaEur: Double
    var totale: Double
    var pdfData: Data?
    var firmaClienteData: Data?
    var firmaData: Date?
    var nomeFirmatario: String
    var createdAt: Date
    var updatedAt: Date

    var cantiere: Cantiere?

    @Relationship(deleteRule: .cascade, inverse: \VocePreventivo.preventivo)
    var voci: [VocePreventivo] = []

    var vociOrdinate: [VocePreventivo] {
        voci.sorted { $0.ordine < $1.ordine }
    }

    init(
        id: UUID = UUID(),
        numero: String = "",
        dataEmissione: Date = Date(),
        validitaGiorni: Int = 30,
        condizioniPagamento: String = "",
        tempiConsegna: String = "",
        note: String = "",
        mostraDettaglioMateriali: Bool = true,
        mostraPrezziPerFacciata: Bool = false,
        margineGlobalePerc: Double = 0,
        ivaPerc: Double = 22,
        imponibile: Double = 0,
        ivaEur: Double = 0,
        totale: Double = 0,
        cantiere: Cantiere? = nil
    ) {
        self.id = id
        self.numero = numero
        self.dataEmissione = dataEmissione
        self.validitaGiorni = validitaGiorni
        self.condizioniPagamento = condizioniPagamento
        self.tempiConsegna = tempiConsegna
        self.note = note
        self.mostraDettaglioMateriali = mostraDettaglioMateriali
        self.mostraPrezziPerFacciata = mostraPrezziPerFacciata
        self.margineGlobalePerc = margineGlobalePerc
        self.ivaPerc = ivaPerc
        self.imponibile = imponibile
        self.ivaEur = ivaEur
        self.totale = totale
        self.nomeFirmatario = ""
        self.cantiere = cantiere
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
