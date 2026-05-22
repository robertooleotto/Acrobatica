import SwiftUI

/// Dettaglio cantiere: meta + lista facciate (rilievi). Tap "Nuovo rilievo" → AR.
struct DettaglioCantiereView: View {
    @ObservedObject var cantiere: Cantiere
    @State private var rilievoInCattura: Rilievo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                facciateSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.paper)
        .navigationTitle(cantiere.nome)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { iniziaNuovoRilievo() } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .fullScreenCover(item: $rilievoInCattura) { r in
            CatturaARView(rilievo: r,
                          onCompletato: { rilievoInCattura = nil },
                          onAnnulla:    { rilievoInCattura = nil })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.navy).frame(width: 56, height: 56)
                    Image(systemName: "building.2.fill")
                        .foregroundStyle(Theme.yellow).font(.system(size: 22))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cantiere.cliente).font(Theme.Typo.body(13)).foregroundStyle(Theme.muted)
                    Text(cantiere.nome).font(Theme.Typo.title(20))
                        .foregroundStyle(Theme.navy)
                }
                Spacer()
            }
            if !cantiere.indirizzo.isEmpty {
                Label(cantiere.indirizzo, systemImage: "mappin.and.ellipse")
                    .font(Theme.Typo.body(14))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(16)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hair, lineWidth: 1))
    }

    private var facciateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Facciate").font(Theme.Typo.title(17)).foregroundStyle(Theme.navy)
                Spacer()
                Text("\(cantiere.rilievi.count)").font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
            }
            if cantiere.rilievi.isEmpty {
                VStack(spacing: 12) {
                    Text("Nessun rilievo ancora.")
                        .font(Theme.Typo.body()).foregroundStyle(Theme.muted)
                    BrandButton(title: "Inizia nuovo rilievo", systemImage: "camera.fill",
                                kind: .primary) {
                        iniziaNuovoRilievo()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Theme.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hair, lineWidth: 1))
            } else {
                ForEach(cantiere.rilievi) { r in
                    NavigationLink {
                        RisultatoPanoramaView(rilievo: r)
                    } label: {
                        rilievoRow(r)
                    }.buttonStyle(.plain)
                }
                BrandButton(title: "Nuovo rilievo", systemImage: "plus", kind: .secondary) {
                    iniziaNuovoRilievo()
                }
            }
        }
    }

    private func rilievoRow(_ r: Rilievo) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.grayBg).frame(width: 56, height: 56)
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(Theme.navy.opacity(0.5))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(r.nome).font(Theme.Typo.title(15, .semibold)).foregroundStyle(Theme.navy)
                HStack(spacing: 6) {
                    StatoChip(text: r.stato.rawValue, tint: tintFor(r.stato))
                    Text("\(r.frameCatturati.count) foto")
                        .font(Theme.Typo.caption(11)).foregroundStyle(Theme.muted)
                    if r.areaNetta > 0 {
                        Text(String(format: "%.1f m²", r.areaNetta))
                            .font(Theme.Typo.caption(11)).foregroundStyle(Theme.muted)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
        }
        .padding(12)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hair, lineWidth: 1))
    }

    private func tintFor(_ s: Rilievo.Stato) -> Color {
        switch s {
        case .bozza:      return Theme.muted
        case .inCattura:  return Theme.warning
        case .elaborato:  return Theme.success
        case .completato: return Theme.success
        }
    }

    private func iniziaNuovoRilievo() {
        let r = Rilievo(nome: "Facciata \(cantiere.rilievi.count + 1)", stato: .inCattura)
        cantiere.rilievi.append(r)
        rilievoInCattura = r
    }
}

/// Chip stato (compatto, brand).
struct StatoChip: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
