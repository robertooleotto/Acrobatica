import SwiftUI

/// 0.3 Home / Dashboard — saluto, KPI, azioni rapide, ultimi cantieri/preventivi.
struct HomeView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var router: TabRouter
    @State private var showNuovoCantiere = false

    private var nome: String { app.utenteNome.split(separator: " ").first.map(String.init) ?? "" }
    private var dataOggi: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: .now).capitalized
    }
    private var daInviare: Int { app.preventivi.filter { $0.stato == .bozza }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    saluto
                    if app.cantieri.isEmpty {
                        EmptyStateView(systemImage: "building.2", title: "Inizia da qui",
                                       subtitle: "Crea il tuo primo cantiere per avviare un rilievo",
                                       cta: "Crea il tuo primo cantiere",
                                       onCta: { showNuovoCantiere = true })
                    } else {
                        kpiRow
                        azioni
                        SectionHeader(title: "Ultimi cantieri", action: "Vedi tutti") { router.selected = .cantieri }
                        ForEach(app.cantieri.prefix(3)) { c in
                            NavigationLink { DettaglioCantiereView(cantiere: c) } label: { cantiereRow(c) }
                                .buttonStyle(.plain)
                        }
                        SectionHeader(title: "Preventivi recenti", action: "Vedi tutti") { router.selected = .preventivi }
                        ForEach(app.preventivi.prefix(2)) { p in
                            NavigationLink { AnteprimaPreventivoView(preventivo: p) } label: { prevRow(p) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Theme.paper.ignoresSafeArea())
            .sheet(isPresented: $showNuovoCantiere) {
                NuovoCantiereSheet { c in
                    app.cantieri.insert(c, at: 0)
                    showNuovoCantiere = false
                }
            }
        }
    }

    private var saluto: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ciao, \(nome)").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.navy)
            Text(dataOggi).font(Theme.Typo.body(14)).foregroundStyle(Theme.muted)
        }
    }

    private var kpiRow: some View {
        HStack(spacing: 12) {
            MetricCard(label: "Cantieri attivi", value: "\(app.cantieri.count)")
            MetricCard(label: "Da inviare", value: "\(daInviare)", highlight: true)
            MetricCard(label: "m² questo mese", value: "\(Int(app.metriTotali))")
        }
    }

    private var azioni: some View {
        HStack(spacing: 10) {
            BrandButton(title: "Nuovo cantiere", systemImage: "plus", kind: .primary) {
                showNuovoCantiere = true
            }
            BrandButton(title: "Nuovo rilievo", systemImage: "camera.fill", kind: .secondary) {
                router.selected = .cantieri
            }
        }
    }

    private func cantiereRow(_ c: Cantiere) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "building.2.fill", size: 44, glyph: 19)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.nome).font(Theme.Typo.body(15, .semibold)).foregroundStyle(Theme.navy)
                Text(c.cliente).font(Theme.Typo.body(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .acroCard(radius: 14, padding: 12)
    }

    private func prevRow(_ p: Preventivo) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "doc.text.fill", size: 44, bg: Theme.grayBg, fg: Theme.navy.opacity(0.5), glyph: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.numero).font(Theme.Typo.mono(13)).foregroundStyle(Theme.navy)
                StatoChip(text: p.stato.etichetta, tint: p.stato.tint)
            }
            Spacer()
            Text(p.totale.eur).font(Theme.Typo.mono(14)).foregroundStyle(Theme.navy)
        }
        .acroCard(radius: 14, padding: 12)
    }
}
