import SwiftUI

/// 6.3 Listino materiali / prezzi.
/// Doppia modalità: tab autonomo (consultazione) o selezione multipla (da preventivo).
struct ListinoView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var selectionMode: Bool = false
    var onInsert: (([VoceListino]) -> Void)? = nil

    @State private var selezione: Set<UUID> = []
    @State private var showNuova = false

    private var nSel: Int { selezione.count }

    var body: some View {
        if selectionMode {
            // Presentato come sheet dal preventivo → serve uno stack proprio.
            NavigationStack {
                contenuto
                    .navigationTitle("Aggiungi dal listino")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } } }
            }
        } else {
            // Pushato dalle Impostazioni → usa lo stack ambientale.
            contenuto
                .navigationTitle("Listino")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showNuova = true } label: { Image(systemName: "plus") }
                    }
                }
        }
    }

    private var contenuto: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(app.listinoPerCategoria, id: \.categoria) { gruppo in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(gruppo.categoria.uppercased())
                                .font(.system(size: 10, weight: .semibold)).kerning(0.5)
                                .foregroundStyle(Theme.muted).padding(.leading, 2)
                            VStack(spacing: 0) {
                                ForEach(Array(gruppo.voci.enumerated()), id: \.element.id) { i, v in
                                    voceRow(v)
                                    if i < gruppo.voci.count - 1 { Divider().overlay(Theme.hair) }
                                }
                            }
                            .acroCard(radius: 16, padding: 14)
                        }
                    }

                    if !selectionMode {
                        Text("Tocca una voce per modificarla o eliminarla")
                            .font(Theme.Typo.caption(12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, selectionMode ? 110 : 40)
            }
            .background(Theme.paper.ignoresSafeArea())

            if selectionMode {
                BrandButton(title: nSel > 0 ? "Inserisci \(nSel) voc\(nSel == 1 ? "e" : "i") nel preventivo" : "Seleziona le voci",
                            systemImage: "checkmark", kind: .primary) {
                    let scelte = app.listino.filter { selezione.contains($0.id) }
                    onInsert?(scelte)
                    dismiss()
                }
                .disabled(nSel == 0)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showNuova) { NuovaVoceListinoSheet() }
    }

    private func voceRow(_ v: VoceListino) -> some View {
        Button {
            guard selectionMode else { return }
            if selezione.contains(v.id) { selezione.remove(v.id) } else { selezione.insert(v.id) }
        } label: {
            HStack(spacing: 10) {
                if selectionMode {
                    let on = selezione.contains(v.id)
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(on ? Theme.navy : Theme.white)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? .clear : Theme.hair2, lineWidth: 1.5))
                        if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.yellow) }
                    }
                    .frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(v.descrizione).font(Theme.Typo.body(14, .medium)).foregroundStyle(Theme.navy)
                    Text(v.unita).font(Theme.Typo.mono(11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text(v.prezzoUnitario.eur).font(Theme.Typo.mono(14)).foregroundStyle(Theme.navy)
                if !selectionMode {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheet nuova voce listino

struct NuovaVoceListinoSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var descrizione = ""
    @State private var unita = ""
    @State private var prezzo = ""
    @State private var categoria = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSField(label: "Descrizione", text: $descrizione, placeholder: "Es. Rasatura armata")
                    HStack(spacing: 10) {
                        DSField(label: "Unità", text: $unita, placeholder: "m² / h / pz")
                        DSField(label: "Prezzo unitario", text: $prezzo, placeholder: "0,00", systemImage: "eurosign", keyboard: .decimalPad)
                    }
                    DSField(label: "Categoria", text: $categoria, placeholder: "Es. Superfici", systemImage: "tag")
                }
                .padding(16)
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Nuova voce")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let p = Double(prezzo.replacingOccurrences(of: ",", with: ".")) ?? 0
                        app.listino.append(VoceListino(descrizione: descrizione,
                                                       unita: unita.isEmpty ? "pz" : unita,
                                                       prezzoUnitario: p,
                                                       categoria: categoria.isEmpty ? "Generale" : categoria))
                        dismiss()
                    }.disabled(descrizione.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
