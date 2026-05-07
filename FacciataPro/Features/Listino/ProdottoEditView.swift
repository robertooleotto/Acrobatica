import SwiftUI
import SwiftData

struct ProdottoEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let prodotto: Prodotto?

    @State private var nome = ""
    @State private var brand = ""
    @State private var categoria: CategoriaProdotto = .altro
    @State private var unita: UnitaProdotto = .litro
    @State private var formato: String = ""
    @State private var prezzo: String = ""
    @State private var resa: String = ""
    @State private var abbondamento: Double = 1.15
    @State private var mani: Int = 2
    @State private var note: String = ""

    private var canSave: Bool {
        !nome.isEmpty &&
        Double(formato.replacingOccurrences(of: ",", with: ".")) ?? 0 > 0 &&
        Double(prezzo.replacingOccurrences(of: ",", with: ".")) ?? 0 > 0 &&
        Double(resa.replacingOccurrences(of: ",", with: ".")) ?? 0 > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identificazione") {
                    TextField("Nome commerciale *", text: $nome)
                    TextField("Brand", text: $brand)
                    Picker("Categoria", selection: $categoria) {
                        ForEach(CategoriaProdotto.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                }

                Section("Confezione") {
                    Picker("Unità", selection: $unita) {
                        ForEach(UnitaProdotto.allCases) { u in
                            Text(u.simbolo).tag(u)
                        }
                    }
                    TextField("Formato vendita *", text: $formato)
                        .keyboardType(.decimalPad)
                    TextField("Prezzo unitario (€/\(unita.simbolo)) *", text: $prezzo)
                        .keyboardType(.decimalPad)
                }

                Section("Resa e applicazione") {
                    TextField("Resa (m²/unità) *", text: $resa)
                        .keyboardType(.decimalPad)
                    Stepper("Coeff. abbondamento: \(abbondamento, specifier: "%.2f")",
                            value: $abbondamento, in: 1.0...2.0, step: 0.05)
                    Stepper("Mani consigliate: \(mani)",
                            value: $mani, in: 1...5)
                }

                Section("Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Button(prodotto == nil ? "Crea prodotto" : "Salva modifiche") {
                        salva()
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle(prodotto == nil ? "Nuovo prodotto" : "Modifica prodotto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .onAppear { popolaSeEdit() }
        }
    }

    private func popolaSeEdit() {
        guard let p = prodotto else { return }
        nome = p.nomeCommerciale
        brand = p.brand
        categoria = p.categoria
        unita = p.unita
        formato = String(p.formatoVendita)
        prezzo = String(p.prezzoUnitario)
        resa = String(p.resaMqPerUnita)
        abbondamento = p.coefficienteAbbondamento
        mani = p.maniConsigliate
        note = p.note
    }

    private func salva() {
        let f = Double(formato.replacingOccurrences(of: ",", with: ".")) ?? 0
        let pz = Double(prezzo.replacingOccurrences(of: ",", with: ".")) ?? 0
        let r = Double(resa.replacingOccurrences(of: ",", with: ".")) ?? 0

        if let p = prodotto {
            p.nomeCommerciale = nome
            p.brand = brand
            p.categoria = categoria
            p.unita = unita
            p.formatoVendita = f
            p.prezzoUnitario = pz
            p.resaMqPerUnita = r
            p.coefficienteAbbondamento = abbondamento
            p.maniConsigliate = mani
            p.note = note
            p.updatedAt = Date()
        } else {
            let nuovo = Prodotto(
                nomeCommerciale: nome,
                brand: brand,
                categoria: categoria,
                unita: unita,
                formatoVendita: f,
                prezzoUnitario: pz,
                resaMqPerUnita: r,
                coefficienteAbbondamento: abbondamento,
                maniConsigliate: mani,
                note: note
            )
            context.insert(nuovo)
        }
        try? context.save()
        dismiss()
    }
}
