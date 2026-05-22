import SwiftUI

/// Editor / anteprima preventivo. Voci + manodopera + IVA + totale.
/// CTA: PDF, invia/firma.
struct AnteprimaPreventivoView: View {
    @ObservedObject var preventivo: Preventivo
    @State private var showPDF = false
    @State private var showFirma = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                vociSection
                manodoperaSection
                totaliSection
                actionButtons
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .background(Theme.paper)
        .navigationTitle(preventivo.numero)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPDF) { PDFPreventivoView(preventivo: preventivo) }
        .navigationDestination(isPresented: $showFirma) { FirmaClienteView(preventivo: preventivo) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLIENTE").font(.system(size: 10, weight: .semibold)).kerning(0.5)
                .foregroundStyle(Theme.muted)
            TextField("Nome cliente", text: $preventivo.clienteNome)
                .font(Theme.Typo.title(18))
                .textFieldStyle(.plain)
            Divider()
            HStack {
                StatoChip(text: preventivo.stato.rawValue.capitalized,
                          tint: preventivo.stato == .bozza ? Theme.muted : Theme.success)
                Spacer()
                Text("Validità: \(preventivo.validitaGiorni) giorni")
                    .font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
            }
        }
        .padding(14)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hair, lineWidth: 1))
    }

    private var vociSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Voci di lavoro").font(Theme.Typo.title(15)).foregroundStyle(Theme.navy)
                Spacer()
                Button {
                    preventivo.voci.append(VoceLavoro(descrizione: "Nuova voce"))
                } label: {
                    Label("Aggiungi", systemImage: "plus")
                        .font(Theme.Typo.caption(12, .semibold))
                        .foregroundColor(Theme.navy)
                }
            }
            ForEach($preventivo.voci) { $v in
                VStack(spacing: 6) {
                    TextField("Descrizione", text: $v.descrizione)
                        .font(Theme.Typo.body(15, .semibold))
                    HStack(spacing: 8) {
                        TextField("Quantità", value: $v.quantita, format: .number)
                            .keyboardType(.decimalPad)
                        Text(v.unita).foregroundStyle(Theme.muted)
                        Spacer()
                        TextField("€/u", value: $v.prezzoUnitario, format: .number)
                            .keyboardType(.decimalPad)
                            .frame(width: 80)
                        Text(String(format: "= € %.2f", v.subtotale))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.navy)
                    }
                    .font(Theme.Typo.body(13))
                }
                .padding(10)
                .background(Theme.grayBg, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(14)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hair, lineWidth: 1))
    }

    private var manodoperaSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Manodopera").font(Theme.Typo.title(15)).foregroundStyle(Theme.navy)
                Spacer()
            }
            HStack {
                Text("Ore")
                Spacer()
                TextField("0", value: $preventivo.manodoperaOre, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80).keyboardType(.decimalPad)
            }
            HStack {
                Text("Tariffa €/h")
                Spacer()
                TextField("0", value: $preventivo.tariffaOraria, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80).keyboardType(.decimalPad)
            }
        }
        .padding(14)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hair, lineWidth: 1))
    }

    private var totaliSection: some View {
        VStack(spacing: 8) {
            row("Imponibile", value: preventivo.imponibile)
            row("IVA \(Int(preventivo.ivaPct))%", value: preventivo.iva)
            Divider()
            HStack {
                Text("TOTALE").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.navy)
                Spacer()
                Text(String(format: "€ %.2f", preventivo.totale))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.navy)
            }
        }
        .padding(14)
        .background(Theme.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.yellow, lineWidth: 1))
    }

    private func row(_ label: String, value: Double) -> some View {
        HStack {
            Text(label).font(Theme.Typo.body(14)).foregroundStyle(Theme.muted)
            Spacer()
            Text(String(format: "€ %.2f", value))
                .font(Theme.Typo.body(14, .semibold)).foregroundStyle(Theme.navy)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            BrandButton(title: "Anteprima PDF", systemImage: "doc.richtext", kind: .secondary) {
                showPDF = true
            }
            BrandButton(title: "Firma cliente", systemImage: "signature", kind: .primary) {
                showFirma = true
            }
        }
    }
}
