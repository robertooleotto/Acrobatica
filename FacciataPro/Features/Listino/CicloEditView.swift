import SwiftUI
import SwiftData

struct CicloEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let ciclo: CicloLavorazione?

    @Query(sort: \Prodotto.nomeCommerciale) private var prodotti: [Prodotto]

    @State private var nome = ""
    @State private var categoria: CategoriaCiclo = .esterno
    @State private var manodopera: String = "0"
    @State private var note = ""
    @State private var stepsBozza: [StepBozza] = []

    private struct StepBozza: Identifiable {
        let id = UUID()
        var prodottoId: UUID?
        var mani: Int = 2
        var ordine: Int = 1
    }

    private var canSave: Bool { !nome.isEmpty }

    private var costoMaterialiPerMq: Double {
        stepsBozza.reduce(0.0) { acc, s in
            guard let pid = s.prodottoId,
                  let p = prodotti.first(where: { $0.id == pid }),
                  p.resaMqPerUnita > 0 else { return acc }
            let costoPerMqPerMano = (p.prezzoUnitario / p.resaMqPerUnita) * p.coefficienteAbbondamento
            return acc + costoPerMqPerMano * Double(s.mani)
        }
    }

    private var costoTotalePerMq: Double {
        let mq = Double(manodopera.replacingOccurrences(of: ",", with: ".")) ?? 0
        return costoMaterialiPerMq + mq
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identificazione") {
                    TextField("Nome ciclo *", text: $nome)
                    Picker("Categoria", selection: $categoria) {
                        ForEach(CategoriaCiclo.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                }

                Section("Step prodotti") {
                    ForEach($stepsBozza) { $s in
                        VStack(alignment: .leading) {
                            Picker("Prodotto", selection: $s.prodottoId) {
                                Text("Seleziona…").tag(UUID?.none)
                                ForEach(prodotti) { p in
                                    Text(p.nomeCommerciale).tag(UUID?.some(p.id))
                                }
                            }
                            Stepper("Mani: \(s.mani)", value: $s.mani, in: 1...5)
                        }
                    }
                    .onDelete { idx in
                        stepsBozza.remove(atOffsets: idx)
                        rinumeraSteps()
                    }
                    Button {
                        let next = stepsBozza.count + 1
                        stepsBozza.append(StepBozza(ordine: next))
                    } label: {
                        Label("Aggiungi step", systemImage: "plus")
                    }
                }

                Section("Manodopera") {
                    TextField("€/mq", text: $manodopera)
                        .keyboardType(.decimalPad)
                }

                Section("Anteprima costi") {
                    LabeledContent("Materiali", value: String(format: "%.2f €/mq", costoMaterialiPerMq))
                    LabeledContent("Manodopera", value: "\(manodopera) €/mq")
                    LabeledContent("Totale", value: String(format: "%.2f €/mq", costoTotalePerMq))
                        .bold()
                }

                Section("Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Button(ciclo == nil ? "Crea ciclo" : "Salva modifiche") {
                        salva()
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle(ciclo == nil ? "Nuovo ciclo" : "Modifica ciclo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .onAppear { popolaSeEdit() }
        }
    }

    private func rinumeraSteps() {
        for i in stepsBozza.indices {
            stepsBozza[i].ordine = i + 1
        }
    }

    private func popolaSeEdit() {
        guard let c = ciclo else { return }
        nome = c.nome
        categoria = c.categoria
        manodopera = String(c.manodoperaEurMq)
        note = c.note
        stepsBozza = c.stepsOrdinati.map { s in
            StepBozza(prodottoId: s.prodotto?.id, mani: s.mani, ordine: s.ordine)
        }
    }

    private func salva() {
        let mq = Double(manodopera.replacingOccurrences(of: ",", with: ".")) ?? 0

        let target: CicloLavorazione
        if let c = ciclo {
            c.nome = nome
            c.categoria = categoria
            c.manodoperaEurMq = mq
            c.note = note
            c.updatedAt = Date()
            for old in c.steps { context.delete(old) }
            target = c
        } else {
            let nuovo = CicloLavorazione(
                nome: nome, categoria: categoria,
                manodoperaEurMq: mq, note: note
            )
            context.insert(nuovo)
            target = nuovo
        }

        rinumeraSteps()
        for s in stepsBozza {
            guard let pid = s.prodottoId,
                  let p = prodotti.first(where: { $0.id == pid }) else { continue }
            let step = StepCiclo(ordine: s.ordine, mani: s.mani, ciclo: target, prodotto: p)
            context.insert(step)
            target.steps.append(step)
        }

        try? context.save()
        dismiss()
    }
}
