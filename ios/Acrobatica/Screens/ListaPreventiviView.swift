import SwiftUI

/// Lista preventivi. Senior vede tutti; operatore vede i propri (per ora vede tutti
/// dato che l'auth multi-utente non è ancora wired).
struct ListaPreventiviView: View {
    @EnvironmentObject var app: AppState
    @State private var filtro: Filtro = .tutti

    enum Filtro: String, CaseIterable { case tutti, bozza, inviato, accettato }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: $filtro) {
                    ForEach(Filtro.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if filtrati.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Theme.muted)
                        Text("Nessun preventivo")
                            .font(Theme.Typo.title()).foregroundStyle(Theme.navy)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filtrati) { p in
                                NavigationLink {
                                    AnteprimaPreventivoView(preventivo: p)
                                } label: {
                                    row(p)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .background(Theme.paper)
            .navigationTitle("Preventivi")
        }
    }

    private var filtrati: [Preventivo] {
        app.preventivi.filter {
            switch filtro {
            case .tutti: return true
            case .bozza: return $0.stato == .bozza
            case .inviato: return $0.stato == .inviato
            case .accettato: return $0.stato == .accettato
            }
        }
    }

    private func row(_ p: Preventivo) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.grayBg).frame(width: 50, height: 50)
                Image(systemName: "doc.text.fill").foregroundStyle(Theme.navy)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(p.numero).font(Theme.Typo.title(15, .semibold)).foregroundStyle(Theme.navy)
                Text(p.clienteNome).font(Theme.Typo.body(13)).foregroundStyle(Theme.muted)
                StatoChip(text: p.stato.rawValue.capitalized, tint: tintFor(p.stato))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "€ %.2f", p.totale))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.navy)
                Text(p.data.formatted(date: .abbreviated, time: .omitted))
                    .font(Theme.Typo.caption(11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hair, lineWidth: 1))
    }

    private func tintFor(_ s: Preventivo.Stato) -> Color {
        switch s {
        case .bozza:     return Theme.muted
        case .inviato:   return Theme.warning
        case .accettato: return Theme.success
        case .rifiutato: return Theme.danger
        case .scaduto:   return Theme.muted
        }
    }
}
