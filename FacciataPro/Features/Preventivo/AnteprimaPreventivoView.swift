import SwiftUI
import SwiftData

struct AnteprimaPreventivoView: View {
    @Bindable var cantiere: Cantiere
    @Environment(\.modelContext) private var context

    @AppStorage("default.iva") private var ivaDefault: Double = 22
    @AppStorage("default.validitaGiorni") private var validitaDefault: Int = 30
    @AppStorage("default.margine") private var margineDefault: Double = 10
    @AppStorage("default.numerazionePrefix") private var prefisso: String = "PREV"

    @Query(sort: \CicloLavorazione.nome) private var cicli: [CicloLavorazione]
    @Query(sort: \VoceAccessoria.nome) private var vociAccessorie: [VoceAccessoria]

    @State private var margine: Double = 10
    @State private var iva: Double = 22
    @State private var validita: Int = 30
    @State private var mostraDettaglio = true
    @State private var mostraPerFacciata = false
    @State private var condizioni = "Pagamento 30% all'avvio, saldo a fine lavori."
    @State private var quantitaAccessorie: [UUID: Double] = [:]
    @State private var preventivoGenerato: Preventivo?
    @State private var apriPDF = false

    private var cicliById: [UUID: CicloLavorazione] {
        Dictionary(uniqueKeysWithValues: cicli.map { ($0.id, $0) })
    }

    private var facciateConCiclo: [Facciata] {
        cantiere.facciate.filter { $0.cicloLavorazioneId != nil && cicliById[$0.cicloLavorazioneId!] != nil }
    }

    private var canGenerare: Bool {
        !facciateConCiclo.isEmpty && facciateConCiclo.count == cantiere.facciate.count
    }

    private var risultato: PreventivoBuilder.ComputedResult {
        let accessorieSelezionate: [(voce: VoceAccessoria, quantita: Double)] =
            quantitaAccessorie.compactMap { id, q in
                guard q > 0, let v = vociAccessorie.first(where: { $0.id == id }) else { return nil }
                return (voce: v, quantita: q)
            }

        return PreventivoBuilder.calcola(
            facciate: cantiere.facciate,
            cicliById: cicliById,
            vociAccessorie: accessorieSelezionate,
            params: PricingParams(margineGlobalePerc: margine, ivaPerc: iva)
        )
    }

    var body: some View {
        Form {
            sezioneCantiere
            sezioneFacciate
            sezioneAccessorie
            sezioneParametri
            sezioneCondizioni
            sezioneVisibilita
            sezioneTotali

            Section {
                Button {
                    generaEApri()
                } label: {
                    Label("Genera preventivo & PDF", systemImage: "doc.text.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canGenerare)

                if !canGenerare {
                    Text("Tutte le facciate devono avere un ciclo selezionato.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Anteprima preventivo")
        .onAppear { applicaDefault() }
        .navigationDestination(isPresented: $apriPDF) {
            if let prev = preventivoGenerato {
                PDFPreventivoView(preventivo: prev, cantiere: cantiere)
            }
        }
    }

    private var sezioneCantiere: some View {
        Section("Cantiere") {
            LabeledContent("Cliente", value: cantiere.cliente?.nome ?? "—")
            LabeledContent("Cantiere", value: cantiere.nome)
            LabeledContent("Facciate", value: "\(cantiere.facciate.count)")
        }
    }

    private var sezioneFacciate: some View {
        Section("Facciate incluse") {
            if cantiere.facciate.isEmpty {
                Text("Nessuna facciata disponibile").foregroundStyle(.secondary)
            } else {
                ForEach(cantiere.facciate) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(f.nome.isEmpty ? "Facciata" : f.nome)
                            Spacer()
                            Text("\(f.superficieNettaMq, specifier: "%.1f") m²").foregroundStyle(.secondary)
                        }
                        if let cid = f.cicloLavorazioneId, let c = cicliById[cid] {
                            Text("Ciclo: \(c.nome)")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        } else {
                            Text("⚠ Nessun ciclo selezionato")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private var sezioneAccessorie: some View {
        Section("Voci accessorie") {
            if vociAccessorie.isEmpty {
                Text("Nessuna voce accessoria configurata.").foregroundStyle(.secondary)
            } else {
                ForEach(vociAccessorie) { v in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(v.nome)
                            Text("\(v.unita.label) · \(v.prezzo, specifier: "%.0f") €")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper("Q.tà \(quantitaAccessorie[v.id, default: 0], specifier: "%.0f")",
                                value: Binding(
                                    get: { quantitaAccessorie[v.id, default: 0] },
                                    set: { quantitaAccessorie[v.id] = $0 }
                                ),
                                in: 0...100, step: 1)
                            .labelsHidden()
                            .frame(maxWidth: 120)
                    }
                }
            }
        }
    }

    private var sezioneParametri: some View {
        Section("Parametri economici") {
            Stepper("Margine globale: \(margine, specifier: "%.0f")%",
                    value: $margine, in: 0...100, step: 1)
            Stepper("IVA: \(iva, specifier: "%.0f")%",
                    value: $iva, in: 0...30, step: 1)
            Stepper("Validità: \(validita) gg",
                    value: $validita, in: 7...365, step: 1)
        }
    }

    private var sezioneCondizioni: some View {
        Section("Condizioni") {
            TextField("Condizioni di pagamento", text: $condizioni, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    private var sezioneVisibilita: some View {
        Section("Visibilità nel PDF") {
            Toggle("Dettaglio materiali", isOn: $mostraDettaglio)
            Toggle("Prezzi per facciata", isOn: $mostraPerFacciata)
        }
    }

    private var sezioneTotali: some View {
        let r = risultato
        return Section("Totali") {
            LabeledContent("Subtotale", value: String(format: "%.2f €", r.subtotale))
            LabeledContent("Con margine", value: String(format: "%.2f €", r.conMargine))
            LabeledContent("IVA", value: String(format: "%.2f €", r.iva))
            LabeledContent("Totale", value: String(format: "%.2f €", r.totale))
                .font(.body.bold())
        }
    }

    private func applicaDefault() {
        margine = margineDefault
        iva = ivaDefault
        validita = validitaDefault
    }

    private func generaEApri() {
        let r = risultato
        let prev = PreventivoBuilder.persisti(
            result: r,
            cantiere: cantiere,
            params: PricingParams(margineGlobalePerc: margine, ivaPerc: iva),
            validitaGiorni: validita,
            condizioniPagamento: condizioni,
            prefissoNumero: prefisso,
            mostraDettaglio: mostraDettaglio,
            mostraPerFacciata: mostraPerFacciata,
            context: context
        )
        preventivoGenerato = prev
        apriPDF = true
    }
}
