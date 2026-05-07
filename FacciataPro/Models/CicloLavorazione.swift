import Foundation
import SwiftData

@Model
final class CicloLavorazione {
    @Attribute(.unique) var id: UUID
    var nome: String
    var categoriaRaw: String
    var manodoperaEurMq: Double
    var note: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \StepCiclo.ciclo)
    var steps: [StepCiclo] = []

    var categoria: CategoriaCiclo {
        get { CategoriaCiclo(rawValue: categoriaRaw) ?? .esterno }
        set { categoriaRaw = newValue.rawValue }
    }

    var stepsOrdinati: [StepCiclo] {
        steps.sorted { $0.ordine < $1.ordine }
    }

    init(
        id: UUID = UUID(),
        nome: String = "",
        categoria: CategoriaCiclo = .esterno,
        manodoperaEurMq: Double = 0,
        note: String = ""
    ) {
        self.id = id
        self.nome = nome
        self.categoriaRaw = categoria.rawValue
        self.manodoperaEurMq = manodoperaEurMq
        self.note = note
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
