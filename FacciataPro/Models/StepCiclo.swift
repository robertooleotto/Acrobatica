import Foundation
import SwiftData

@Model
final class StepCiclo {
    @Attribute(.unique) var id: UUID
    var ordine: Int
    var mani: Int

    var ciclo: CicloLavorazione?
    var prodotto: Prodotto?

    init(
        id: UUID = UUID(),
        ordine: Int = 1,
        mani: Int = 2,
        ciclo: CicloLavorazione? = nil,
        prodotto: Prodotto? = nil
    ) {
        self.id = id
        self.ordine = ordine
        self.mani = mani
        self.ciclo = ciclo
        self.prodotto = prodotto
    }
}
