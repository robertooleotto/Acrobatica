import SwiftUI
import SwiftData

struct SelezioneCicloView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    @Query(sort: \CicloLavorazione.nome) private var cicli: [CicloLavorazione]
    @Query(sort: \VoceAccessoria.nome) private var vociAcc: [VoceAccessoria]

    @State private var vociSelezionate: Set<UUID> = []

    var body: some View {
        Form {
            Section("Superficie netta") {
                HStack {
                    Text("Da preventivare")
                    Spacer()
                    Text("\(stato.superficieNettaMq, specifier: "%.1f") m²")
                        .foregroundStyle(.tint)
                        .bold()
                }
            }

            Section("Ciclo di lavorazione") {
                if cicli.isEmpty {
                    Text("Nessun ciclo configurato. Aggiungi un ciclo dal Listino.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(cicli) { c in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(c.nome).font(.headline)
                            Text("\(c.steps.count) step · \(c.manodoperaEurMq, specifier: "%.0f") €/mq manodopera")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if stato.cicloSelezionatoId == c.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        stato.cicloSelezionatoId = c.id
                    }
                }
            }

            Section("Voci accessorie") {
                ForEach(vociAcc) { v in
                    HStack {
                        Image(systemName: vociSelezionate.contains(v.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(vociSelezionate.contains(v.id) ? .tint : .secondary)
                        VStack(alignment: .leading) {
                            Text(v.nome)
                            Text("\(v.unita.label) · \(v.prezzo, specifier: "%.0f") €")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if vociSelezionate.contains(v.id) {
                            vociSelezionate.remove(v.id)
                        } else {
                            vociSelezionate.insert(v.id)
                        }
                    }
                }
            }

            Section {
                Button {
                    onAvanti()
                } label: {
                    Text("Avanti — Riepilogo")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(stato.cicloSelezionatoId == nil)
            }
        }
        .navigationTitle("Ciclo lavorazione")
        .navigationBarTitleDisplayMode(.inline)
    }
}
