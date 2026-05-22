import SwiftUI

/// Anteprima PDF del preventivo. Per ora rendering custom in SwiftUI;
/// generazione PDF reale via PDFKit verrà aggiunta in seguito (TODO).
struct PDFPreventivoView: View {
    @ObservedObject var preventivo: Preventivo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                dettagliCliente
                vociTable
                Divider()
                totaliBlock
                Spacer().frame(height: 8)
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .background(Theme.grayBg.ignoresSafeArea())
        .navigationTitle("Anteprima PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // TODO: generate real PDF with PDFKit + ShareLink.
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Acrobatica")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(Theme.navy)
                Text("Rilievo facciate · Preventivo")
                    .font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(preventivo.numero).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.navy)
                Text(preventivo.data.formatted(date: .long, time: .omitted))
                    .font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
            }
        }
    }

    private var dettagliCliente: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CLIENTE").font(.system(size: 10, weight: .semibold)).kerning(0.5)
                .foregroundStyle(Theme.muted)
            Text(preventivo.clienteNome.isEmpty ? "—" : preventivo.clienteNome)
                .font(Theme.Typo.body(15, .semibold)).foregroundStyle(Theme.navy)
            if !preventivo.cantiereNome.isEmpty {
                Text("Cantiere: \(preventivo.cantiereNome)")
                    .font(Theme.Typo.body(13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var vociTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DESCRIZIONE").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Text("QTÀ").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 50, alignment: .trailing)
                Text("€/U").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 60, alignment: .trailing)
                Text("SUBTOTALE").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .trailing)
            }
            ForEach(preventivo.voci) { v in
                HStack {
                    Text(v.descrizione).font(Theme.Typo.body(13)).foregroundStyle(Theme.navy)
                    Spacer()
                    Text(String(format: "%.1f %@", v.quantita, v.unita)).font(Theme.Typo.body(13)).frame(width: 50, alignment: .trailing)
                    Text(String(format: "%.2f", v.prezzoUnitario)).font(Theme.Typo.body(13)).frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.2f", v.subtotale)).font(Theme.Typo.body(13, .semibold)).frame(width: 80, alignment: .trailing)
                }
                Divider().opacity(0.3)
            }
            if preventivo.manodoperaOre > 0 {
                HStack {
                    Text("Manodopera").font(Theme.Typo.body(13)).foregroundStyle(Theme.navy)
                    Spacer()
                    Text(String(format: "%.1f h", preventivo.manodoperaOre)).font(Theme.Typo.body(13)).frame(width: 50, alignment: .trailing)
                    Text(String(format: "%.2f", preventivo.tariffaOraria)).font(Theme.Typo.body(13)).frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.2f", preventivo.manodoperaOre * preventivo.tariffaOraria))
                        .font(Theme.Typo.body(13, .semibold)).frame(width: 80, alignment: .trailing)
                }
            }
        }
    }

    private var totaliBlock: some View {
        VStack(spacing: 4) {
            row("Imponibile", value: preventivo.imponibile)
            row("IVA \(Int(preventivo.ivaPct))%", value: preventivo.iva)
            HStack {
                Text("TOTALE").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.navy)
                Spacer()
                Text(String(format: "€ %.2f", preventivo.totale))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.navy)
            }
            .padding(.top, 4)
        }
    }

    private func row(_ label: String, value: Double) -> some View {
        HStack {
            Text(label).font(Theme.Typo.body(12)).foregroundStyle(Theme.muted)
            Spacer()
            Text(String(format: "€ %.2f", value)).font(Theme.Typo.body(12)).foregroundStyle(Theme.navy)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Validità preventivo: \(preventivo.validitaGiorni) giorni")
                .font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
            Text("Prezzi IVA esclusa. Pagamento secondo accordi.")
                .font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
        }
    }
}
