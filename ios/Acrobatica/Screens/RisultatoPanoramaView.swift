import SwiftUI

/// Risultato del rilievo: panorama + scala metrica (2 tap) + aperture + m².
/// CTA: genera preventivo, export.
struct RisultatoPanoramaView: View {
    @ObservedObject var rilievo: Rilievo
    @EnvironmentObject var app: AppState
    @State private var elaborazioneInCorso = false
    @State private var stitchedUrl: URL?
    @State private var keystoneUrls: [URL] = []
    @State private var modScala: Bool = false
    @State private var preventivoCreato: Preventivo?
    @State private var showTapPiano = false
    @State private var orthoComposite: URL?
    @State private var errore: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                panoramaCard
                metriche
                aperture
                actionButtons
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.paper)
        .navigationTitle(rilievo.nome)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("PDF", systemImage: "doc.richtext") { /* TODO export PDF */ }
                    Button("CSV", systemImage: "tablecells")    { /* TODO export CSV */ }
                    Button("JSON", systemImage: "curlybraces")  { /* TODO export JSON */ }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task(id: rilievo.id) { await elabora() }
        .fullScreenCover(isPresented: $showTapPiano) {
            if let sid = rilievo.sessionId {
                TapWallPlaneView(
                    rilievo: rilievo, sessionId: sid,
                    onCompletato: { url in
                        showTapPiano = false
                        if let url {
                            orthoComposite = url
                            rilievo.panoramaUrl = url
                            stitchedUrl = url
                        }
                    },
                    onAnnulla: { showTapPiano = false }
                )
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { preventivoCreato != nil },
            set: { if !$0 { preventivoCreato = nil } }
        )) {
            if let p = preventivoCreato { AnteprimaPreventivoView(preventivo: p) }
        }
        .alert("Errore", isPresented: Binding(get: { errore != nil }, set: { if !$0 { errore = nil } })) {
            Button("OK") { errore = nil }
        } message: { Text(errore ?? "") }
    }

    // MARK: – Panorama

    private var panoramaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if elaborazioneInCorso {
                VStack(spacing: 8) {
                    ProgressView().tint(Theme.navy)
                    Text("Elaborazione (stitch + keystone)…")
                        .font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if let url = stitchedUrl {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    case .failure: Text("⚠ panorama non scaricabile").foregroundStyle(Theme.danger)
                    @unknown default: EmptyView()
                    }
                }
            } else {
                Text("Nessun panorama disponibile.")
                    .font(Theme.Typo.body()).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(12)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hair, lineWidth: 1))
    }

    // MARK: – Metriche

    private var metriche: some View {
        HStack(spacing: 12) {
            MetricCard(label: "Area lorda", value: areaString(rilievo.areaLorda))
            MetricCard(label: "Area netta", value: areaString(rilievo.areaNetta), highlight: true)
            MetricCard(label: "Aperture",   value: "\(rilievo.aperture.count)")
        }
    }

    private func areaString(_ m2: Double) -> String {
        m2 > 0 ? String(format: "%.1f m²", m2) : "—"
    }

    // MARK: – Aperture

    private var aperture: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Aperture").font(Theme.Typo.title(15)).foregroundStyle(Theme.navy)
                Spacer()
                Button {
                    let nuova = Apertura(tipo: .finestra)
                    rilievo.aperture.append(nuova)
                } label: {
                    Label("Aggiungi", systemImage: "plus")
                        .font(Theme.Typo.caption(12, .semibold))
                        .foregroundColor(Theme.navy)
                }
            }
            if rilievo.aperture.isEmpty {
                Text("Tocca le finestre/porte sul panorama, oppure aggiungi manualmente.")
                    .font(Theme.Typo.body(13)).foregroundStyle(Theme.muted)
            } else {
                ForEach(rilievo.aperture) { a in
                    HStack {
                        Image(systemName: iconFor(a.tipo))
                            .foregroundStyle(Theme.navy)
                            .frame(width: 28)
                        Text(a.tipo.rawValue.capitalized)
                            .font(Theme.Typo.body(14))
                            .foregroundStyle(Theme.navy)
                        Spacer()
                        if let m = a.areaM2 {
                            Text(String(format: "%.2f m²", m)).font(Theme.Typo.caption(12))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
        .padding(14)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hair, lineWidth: 1))
    }

    private func iconFor(_ t: Apertura.Tipo) -> String {
        switch t {
        case .finestra: return "rectangle.split.2x2"
        case .porta:    return "door.right.hand.open"
        case .balcone:  return "square.split.bottomrightquarter"
        case .altro:    return "square.dashed"
        }
    }

    // MARK: – Action buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            BrandButton(title: "Definisci piano muro (4 tap)", systemImage: "viewfinder.rectangular",
                        kind: .primary) {
                showTapPiano = true
            }
            .disabled(rilievo.sessionId == nil || rilievo.frameCatturati.isEmpty)
            BrandButton(title: "Genera preventivo", systemImage: "doc.text.fill",
                        kind: .secondary) {
                creaPreventivoDaRilievo()
            }
            BrandButton(title: modScala ? "Tocca 2 punti sul panorama" : "Definisci scala (2 tap)",
                        systemImage: "ruler", kind: .ghost) {
                modScala.toggle()
                // TODO: enter scala-tap mode su una sub-view dedicata
            }
        }
    }

    private func creaPreventivoDaRilievo() {
        let n = app.nuovoNumeroPreventivo()
        let cantiereNome = "Cantiere"
        let p = Preventivo(numero: n,
                           clienteNome: "—",
                           cantiereNome: cantiereNome,
                           voci: [
                            VoceLavoro(descrizione: "Tinteggiatura facciata",
                                       quantita: max(rilievo.areaNetta, 1),
                                       unita: "m²",
                                       prezzoUnitario: 18)
                           ],
                           rilievoId: rilievo.id)
        app.preventivi.insert(p, at: 0)
        preventivoCreato = p
    }

    // MARK: – Backend elaborazione

    @MainActor
    private func elabora() async {
        guard let sid = rilievo.sessionId, !rilievo.frameCatturati.isEmpty else { return }
        guard rilievo.panoramaUrl == nil else { return }   // già fatto
        elaborazioneInCorso = true
        defer { elaborazioneInCorso = false }
        do {
            let res = try await BackendAPIClient.shared.processSession(sessionId: sid)
            if let s = res.stitched_url, let u = URL(string: s) {
                stitchedUrl = u
                rilievo.panoramaUrl = u
            }
            if let m = res.net_area_m2 { rilievo.areaNetta = m }
            if let g = res.gross_area_m2 { rilievo.areaLorda = g }
            rilievo.stato = .elaborato
        } catch {
            errore = error.localizedDescription
        }
    }
}

/// Riquadro metrica numerica.
struct MetricCard: View {
    let label: String
    let value: String
    var highlight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(highlight ? Theme.navy : Theme.navy.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(highlight ? Theme.yellow.opacity(0.18) : Theme.white,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(highlight ? Theme.yellow : Theme.hair, lineWidth: 1))
    }
}
