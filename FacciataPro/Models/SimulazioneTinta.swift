import Foundation
import SwiftData

struct ZonaSimulazione: Codable, Hashable {
    var poligono: PoligonoJSON
    var coloreHex: String
    var cicloId: UUID?
}

@Model
final class SimulazioneTinta {
    @Attribute(.unique) var id: UUID
    var nome: String
    var zoneData: Data
    var fotoSimulataData: Data?
    var isSelected: Bool
    var createdAt: Date

    var facciata: Facciata?

    var zone: [ZonaSimulazione] {
        get { (try? JSONDecoder().decode([ZonaSimulazione].self, from: zoneData)) ?? [] }
        set { zoneData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(
        id: UUID = UUID(),
        nome: String = "",
        zone: [ZonaSimulazione] = [],
        fotoSimulataData: Data? = nil,
        isSelected: Bool = false,
        facciata: Facciata? = nil
    ) {
        self.id = id
        self.nome = nome
        self.zoneData = (try? JSONEncoder().encode(zone)) ?? Data()
        self.fotoSimulataData = fotoSimulataData
        self.isSelected = isSelected
        self.facciata = facciata
        self.createdAt = Date()
    }
}
