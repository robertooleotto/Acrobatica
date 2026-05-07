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

@Observable
final class SopralluogoState {
    var fotoData: Data?
    var fotoRaddrizzataData: Data?
    var pixelPerCm: Double = 0
    var larghezzaM: Double = 0
    var altezzaM: Double = 0
    var elementiEsclusi: [(area: Double, tipo: TipoElementoEscluso, nome: String)] = []
    var elementiExtra: [(area: Double, tipo: TipoElementoExtra, nome: String)] = []
    var simulazioniSelezionate: [String] = []
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
