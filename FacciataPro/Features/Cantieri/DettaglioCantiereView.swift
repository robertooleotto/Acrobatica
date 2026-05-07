import SwiftUI
import SwiftData

struct DettaglioCantiereView: View {
    @Bindable var cantiere: Cantiere
    @State private var avviaSopralluogo = false
    @State private var apriPreventivo = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if let cliente = cantiere.cliente {
                        Label(cliente.nome, systemImage: "person")
                    }
                    if !cantiere.indirizzoCantiere.isEmpty {
                        Label(cantiere.indirizzoCantiere, systemImage: "mappin")
                    }
                    Label(cantiere.stato.label, systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }

            Section("Facciate") {
                if cantiere.facciate.isEmpty {
                    Text("Nessuna facciata. Avvia un sopralluogo per aggiungerne.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(cantiere.facciate) { f in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(f.nome.isEmpty ? "Facciata" : f.nome)
                                Text("\(f.superficieNettaMq, specifier: "%.1f") m² netti")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                Button {
                    avviaSopralluogo = true
                } label: {
                    Label("Nuovo sopralluogo", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }

            Section("Preventivi") {
                if cantiere.preventivi.isEmpty {
                    Text("Nessun preventivo generato.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(cantiere.preventivi) { p in
                        NavigationLink {
                            PDFPreventivoView(preventivo: p, cantiere: cantiere)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(p.numero.isEmpty ? "Preventivo" : p.numero)
                                    Text("Totale \(p.totale, specifier: "%.2f") €")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p.firmaClienteData != nil {
                                    Image(systemName: "signature").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Button {
                    apriPreventivo = true
                } label: {
                    Label("Genera preventivo", systemImage: "doc.text.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(cantiere.facciate.isEmpty)
            }

            Section {
                Button("Duplica cantiere") { /* TODO */ }
                Button("Elimina cantiere", role: .destructive) { /* TODO */ }
            }
        }
        .navigationTitle(cantiere.nome)
        .navigationDestination(isPresented: $avviaSopralluogo) {
            SopralluogoCoordinator(cantiere: cantiere)
        }
        .navigationDestination(isPresented: $apriPreventivo) {
            AnteprimaPreventivoView(cantiere: cantiere)
        }
    }
}

#Preview {
    NavigationStack {
        DettaglioCantiereView(cantiere: Cantiere(nome: "Villa Rossi"))
            .modelContainer(for: AppSchema.allModels, inMemory: true)
    }
}
