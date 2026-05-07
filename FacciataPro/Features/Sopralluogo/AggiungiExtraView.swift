import SwiftUI

struct AggiungiExtraView: View {
    @Bindable var stato: SopralluogoState
    @Environment(\.dismiss) private var dismiss

    @State private var tipo: TipoElementoExtra = .balcone
    @State private var nome: String = ""
    @State private var lunghezza: String = ""
    @State private var profondita: String = ""
    @State private var altezza: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo") {
                    Picker("Tipo elemento", selection: $tipo) {
                        ForEach(TipoElementoExtra.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    TextField("Nome (es. Balcone primo piano)", text: $nome)
                }

                Section("Misure") {
                    TextField("Lunghezza (m)", text: $lunghezza)
                        .keyboardType(.decimalPad)
                    TextField("Profondità / sporgenza (m)", text: $profondita)
                        .keyboardType(.decimalPad)
                    TextField("Altezza (m)", text: $altezza)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Button("Aggiungi extra") {
                        salva()
                    }
                }
            }
            .navigationTitle("Aggiungi extra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }

    private func salva() {
        let l = Double(lunghezza.replacingOccurrences(of: ",", with: ".")) ?? 0
        let p = Double(profondita.replacingOccurrences(of: ",", with: ".")) ?? 0
        let h = Double(altezza.replacingOccurrences(of: ",", with: ".")) ?? 0
        let area: Double
        switch tipo {
        case .balcone, .cornicione, .sottogronda:
            area = l * p
        case .lesena, .inferriata, .libero:
            area = l * h
        }
        stato.elementiExtra.append((area: area, tipo: tipo, nome: nome))
        dismiss()
    }
}
