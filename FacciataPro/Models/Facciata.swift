import Foundation
import SwiftData

@Model
final class Facciata {
    @Attribute(.unique) var id: UUID
    var nome: String
    var fotoOriginaleData: Data?
    var fotoRaddrizzataData: Data?
    var homographyMatrix: [Double]
    var pixelPerCm: Double
    var larghezzaM: Double
    var altezzaM: Double
    var superficieLordaMq: Double
    var superficieNettaMq: Double
    var createdAt: Date
    var updatedAt: Date

    var cantiere: Cantiere?

    @Relationship(deleteRule: .cascade, inverse: \ElementoEscluso.facciata)
    var elementiEsclusi: [ElementoEscluso] = []

    @Relationship(deleteRule: .cascade, inverse: \ElementoExtra.facciata)
    var elementiExtra: [ElementoExtra] = []

    @Relationship(deleteRule: .cascade, inverse: \SimulazioneTinta.facciata)
    var simulazioni: [SimulazioneTinta] = []

    init(
        id: UUID = UUID(),
        nome: String = "",
        fotoOriginaleData: Data? = nil,
        fotoRaddrizzataData: Data? = nil,
        homographyMatrix: [Double] = [],
        pixelPerCm: Double = 0,
        larghezzaM: Double = 0,
        altezzaM: Double = 0,
        superficieLordaMq: Double = 0,
        superficieNettaMq: Double = 0,
        cantiere: Cantiere? = nil
    ) {
        self.id = id
        self.nome = nome
        self.fotoOriginaleData = fotoOriginaleData
        self.fotoRaddrizzataData = fotoRaddrizzataData
        self.homographyMatrix = homographyMatrix
        self.pixelPerCm = pixelPerCm
        self.larghezzaM = larghezzaM
        self.altezzaM = altezzaM
        self.superficieLordaMq = superficieLordaMq
        self.superficieNettaMq = superficieNettaMq
        self.cantiere = cantiere
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
