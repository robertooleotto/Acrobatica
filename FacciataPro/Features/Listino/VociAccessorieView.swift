import SwiftUI
import SwiftData

struct VociAccessorieView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VoceAccessoria.nome) private var voci: [VoceAccessoria]

    @State private var apriEdit = false
    @State private var voceInModifica: VoceAccessoria?

    var body: some View {
        List {
            ForEach(voci) { v in
                Button {
                    voceInModifica = v
                    apriEdit = true
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(v.nome).font(.headline)
                            Text(v.unita.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(v.prezzo, specifier: "%.0f") €")
                            .font(.callout.bold())
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { idx in
                for i in idx { context.delete(voci[i]) }
                try? context.save()
            }
        }
        .navigationTitle("Voci accessorie")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    voceInModifica = nil
                    apriEdit = true
                } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .sheet(isPresented: $apriEdit) {
            VoceAccessoriaEditView(voce: voceInModifica)
        }
    }
}

private struct VoceAccessoriaEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let voce: VoceAccessoria?

    @State private var nome = ""
    @State private var unita: UnitaVoceAccessoria = .a_corpo
    @State private var prezzo: String = "0"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome *", text: $nome)
                Picker("Unità", selection: $unita) {
                    ForEach(UnitaVoceAccessoria.allCases) { u in
                        Text(u.label).tag(u)
                    }
                }
                TextField("Prezzo (€)", text: $prezzo)
                    .keyboardType(.decimalPad)
                Section {
                    Button(voce == nil ? "Crea" : "Salva") {
                        salva()
                    }
                    .disabled(nome.isEmpty)
                }
            }
            .navigationTitle(voce == nil ? "Nuova voce" : "Modifica voce")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .onAppear {
                if let v = voce {
                    nome = v.nome
                    unita = v.unita
                    prezzo = String(v.prezzo)
                }
            }
        }
    }

    private func salva() {
        let p = Double(prezzo.replacingOccurrences(of: ",", with: ".")) ?? 0
        if let v = voce {
            v.nome = nome
            v.unita = unita
            v.prezzo = p
            v.updatedAt = Date()
        } else {
            context.insert(VoceAccessoria(nome: nome, unita: unita, prezzo: p))
        }
        try? context.save()
        dismiss()
    }
}
