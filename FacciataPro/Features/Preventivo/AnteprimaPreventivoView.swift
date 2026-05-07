import SwiftUI
import SwiftData

struct AnteprimaPreventivoView: View {
    @Bindable var cantiere: Cantiere

    @State private var margine: Double = 10
    @State private var iva: Double = 22
    @State private var validita: Int = 30
    @State private var mostraDettaglio = true
    @State private var mostraPerFacciata = false
    @State private var condizioni = "Pagamento 30% all'avvio, saldo a fine lavori."
    @State private var apriPDF = false

    var body: some View {
        Form {
            Section("Cantiere") {
                LabeledContent("Cliente", value: cantiere.cliente?.nome ?? "—")
                LabeledContent("Cantiere", value: cantiere.nome)
                LabeledContent("Facciate", value: "\(cantiere.facciate.count)")
            }

            Section("Facciate incluse") {
                if cantiere.facciate.isEmpty {
                    Text("Nessuna facciata disponibile")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cantiere.facciate) { f in
                        HStack {
                            Text(f.nome.isEmpty ? "Facciata" : f.nome)
                            Spacer()
                            Text("\(f.superficieNettaMq, specifier: "%.1f") m²")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Parametri economici") {
                Stepper("Margine globale: \(margine, specifier: "%.0f")%",
                        value: $margine, in: 0...100, step: 1)
                Stepper("IVA: \(iva, specifier: "%.0f")%",
                        value: $iva, in: 0...30, step: 1)
                Stepper("Validità: \(validita) gg",
                        value: $validita, in: 7...365, step: 1)
            }

            Section("Condizioni") {
                TextField("Condizioni di pagamento", text: $condizioni, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section("Visibilità nel PDF") {
                Toggle("Dettaglio materiali", isOn: $mostraDettaglio)
                Toggle("Prezzi per facciata", isOn: $mostraPerFacciata)
            }

            Section {
                Button {
                    apriPDF = true
                } label: {
                    Label("Genera PDF", systemImage: "doc.text.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("Anteprima preventivo")
        .navigationDestination(isPresented: $apriPDF) {
            PDFPreventivoView(cantiere: cantiere)
        }
    }
}
