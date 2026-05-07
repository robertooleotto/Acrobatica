import SwiftUI
import SwiftData

struct NuovoCantiereView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Cliente.nome) private var clienti: [Cliente]

    @State private var nome = ""
    @State private var indirizzo = ""
    @State private var note = ""
    @State private var clienteSelezionato: Cliente?
    @State private var creaNuovoCliente = false
    @State private var nomeNuovoCliente = ""
    @State private var avviaSopralluogo = false

    private var canSave: Bool {
        !nome.isEmpty &&
        (clienteSelezionato != nil || (creaNuovoCliente && !nomeNuovoCliente.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Cantiere") {
                    TextField("Nome cantiere *", text: $nome)
                    TextField("Indirizzo", text: $indirizzo)
                }

                Section("Cliente *") {
                    if !creaNuovoCliente {
                        Picker("Seleziona cliente", selection: $clienteSelezionato) {
                            Text("Nessuno").tag(Cliente?.none)
                            ForEach(clienti) { c in
                                Text(c.nome).tag(Cliente?.some(c))
                            }
                        }
                    } else {
                        TextField("Nome cliente *", text: $nomeNuovoCliente)
                    }
                    Toggle("Crea nuovo cliente", isOn: $creaNuovoCliente)
                }

                Section("Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Button {
                        salva(eAvvia: false)
                    } label: {
                        Text("Salva")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canSave)

                    Button {
                        salva(eAvvia: true)
                    } label: {
                        Label("Salva e inizia sopralluogo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                }
            }
            .navigationTitle("Nuovo cantiere")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }

    private func salva(eAvvia: Bool) {
        let cliente: Cliente
        if creaNuovoCliente {
            cliente = Cliente(nome: nomeNuovoCliente)
            context.insert(cliente)
        } else if let sel = clienteSelezionato {
            cliente = sel
        } else {
            return
        }

        let cantiere = Cantiere(
            nome: nome,
            indirizzoCantiere: indirizzo,
            stato: .bozza,
            note: note,
            cliente: cliente
        )
        context.insert(cantiere)
        try? context.save()
        dismiss()
        // TODO: se eAvvia, naviga al sopralluogo
    }
}

#Preview {
    NuovoCantiereView()
        .modelContainer(for: AppSchema.allModels, inMemory: true)
}
