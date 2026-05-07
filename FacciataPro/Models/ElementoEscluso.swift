import Foundation
import SwiftData

@Model
final class ElementoEscluso {
    @Attribute(.unique) var id: UUID
    var tipoRaw: String
    var nome: String
    var poligonoData: Data
    var areaMq: Double

    var facciata: Facciata?

    var tipo: TipoElementoEscluso {
        get { TipoElementoEscluso(rawValue: tipoRaw) ?? .finestra }
        set { tipoRaw = newValue.rawValue }
    }

    var poligono: PoligonoJSON {
        get { (try? JSONDecoder().decode(PoligonoJSON.self, from: poligonoData)) ?? PoligonoJSON(punti: []) }
        set { poligonoData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(
        id: UUID = UUID(),
        tipo: TipoElementoEscluso = .finestra,
        nome: String = "",
        poligono: PoligonoJSON = PoligonoJSON(punti: []),
        areaMq: Double = 0,
        facciata: Facciata? = nil
    ) {
        self.id = id
        self.tipoRaw = tipo.rawValue
        self.nome = nome
        self.poligonoData = (try? JSONEncoder().encode(poligono)) ?? Data()
        self.areaMq = areaMq
        self.facciata = facciata
    }
}
