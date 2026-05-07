import SwiftUI
import SwiftData

enum SopralluogoStep: Hashable {
    case raddrizzamento
    case calibrazione
    case infissi
    case simulazione
    case ciclo
    case riepilogo
}

struct VarianteTinta: Identifiable, Hashable {
    let id: UUID
    var nome: String
    var coloreHex: String
    var jpegPreview: Data?

    init(id: UUID = UUID(), nome: String, coloreHex: String, jpegPreview: Data? = nil) {
        self.id = id
        self.nome = nome
        self.coloreHex = coloreHex
        self.jpegPreview = jpegPreview
    }
}

@Observable
final class SopralluogoState {
    // Foto originale
    var fotoData: Data?

    // Raddrizzamento: 4 angoli in coordinate normalizzate (0-1) sulla foto originale.
    // Ordine: TL, TR, BR, BL.
    var angoloTL: CGPoint = CGPoint(x: 0.05, y: 0.05)
    var angoloTR: CGPoint = CGPoint(x: 0.95, y: 0.05)
    var angoloBR: CGPoint = CGPoint(x: 0.95, y: 0.95)
    var angoloBL: CGPoint = CGPoint(x: 0.05, y: 0.95)

    // Foto raddrizzata + dimensioni in pixel
    var fotoRaddrizzataData: Data?
    var fotoRaddrizzataWidthPx: Double = 0
    var fotoRaddrizzataHeightPx: Double = 0

    // Calibrazione: 2 punti in coordinate normalizzate sulla foto raddrizzata
    var segmentoStart: CGPoint = CGPoint(x: 0.3, y: 0.5)
    var segmentoEnd: CGPoint = CGPoint(x: 0.7, y: 0.5)
    var misuraSegmentoCm: Double = 90  // default: porta standard

    // Output calibrazione
    var pixelPerCm: Double = 0
    var larghezzaM: Double = 0
    var altezzaM: Double = 0

    // Esclusioni / extra
    var elementiEsclusi: [(area: Double, tipo: TipoElementoEscluso, nome: String)] = []
    var elementiExtra: [(area: Double, tipo: TipoElementoExtra, nome: String)] = []

    // Simulazioni colore (max 4 varianti)
    var variantiTinta: [VarianteTinta] = []
    var varianteSelezionataId: UUID?

    // Ciclo
    var cicloSelezionatoId: UUID?

    var superficieLordaMq: Double { larghezzaM * altezzaM }
    var areaEsclusiTotale: Double { elementiEsclusi.reduce(0) { $0 + $1.area } }
    var areaExtraTotale: Double { elementiExtra.reduce(0) { $0 + $1.area } }
    var superficieNettaMq: Double {
        max(0, superficieLordaMq - areaEsclusiTotale + areaExtraTotale)
    }
}

struct SopralluogoCoordinator: View {
    let cantiere: Cantiere
    @State private var stato = SopralluogoState()
    @State private var path: [SopralluogoStep] = []

    var body: some View {
        CatturaFotoView(stato: stato, onAvanti: {
            path.append(.raddrizzamento)
        })
        .navigationDestination(for: SopralluogoStep.self) { step in
            switch step {
            case .raddrizzamento:
                RaddrizzamentoView(stato: stato) { path.append(.calibrazione) }
            case .calibrazione:
                CalibrazioneView(stato: stato) { path.append(.infissi) }
            case .infissi:
                EsclusioneInfissiView(stato: stato) { path.append(.simulazione) }
            case .simulazione:
                SimulazioneTinteView(stato: stato) { path.append(.ciclo) }
            case .ciclo:
                SelezioneCicloView(stato: stato) { path.append(.riepilogo) }
            case .riepilogo:
                RiepilogoFacciataView(cantiere: cantiere, stato: stato)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SopralluogoCoordinator(cantiere: Cantiere(nome: "Test"))
            .modelContainer(for: AppSchema.allModels, inMemory: true)
    }
}
