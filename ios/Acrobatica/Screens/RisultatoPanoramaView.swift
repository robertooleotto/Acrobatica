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
    @State private var showTapPiano = false       // legacy: 3D-triangulation (sperimentale)
    @State private var showRectifyFacade = false  // NUOVO: 2D homography 4-tap
    @State private var showMeasureScale = false
    @State private var showMarcatura = false      // editor marcatura zone (m²)
    @State private var showEditor3D = false        // editor 3D mesh (pulizia + piani)
    @State private var rectifiedFacadeUrl: URL?
    @State private var metersPerPixel: Double?
    @State private var orthoComposite: URL?
    @State private var errore: String?
    @State private var previewGrandeURL: URL?

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
        .fullScreenCover(isPresented: $showRectifyFacade) {
            if let sid = rilievo.sessionId, let pano = stitchedUrl {
                RectifyFacadeView(
                    sessionId: sid, panoramaURL: pano,
                    onCompletato: { url in
                        showRectifyFacade = false
                        rectifiedFacadeUrl = url
                        rilievo.panoramaUrl = url
                        stitchedUrl = url
                        // Auto-apertura step scala
                        showMeasureScale = true
                    },
                    onAnnulla: { showRectifyFacade = false }
                )
            }
        }
        .fullScreenCover(isPresented: $showMeasureScale) {
            if let sid = rilievo.sessionId, let rect = rectifiedFacadeUrl {
                MeasureScaleView(
                    sessionId: sid, rectifiedURL: rect,
                    onCompletato: { mpp in
                        showMeasureScale = false
                        metersPerPixel = mpp
                    },
                    onAnnulla: { showMeasureScale = false }
                )
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { previewGrandeURL != nil },
            set: { if !$0 { previewGrandeURL = nil } }
        )) {
            if let url = previewGrandeURL {
                FacadeImageFullscreenView(url: url) {
                    previewGrandeURL = nil
                }
            }
        }
        .fullScreenCover(isPresented: $showMarcatura) {
            if let url = stitchedUrl {
                MarcaturaFacciataCaricamentoView(
                    url: url,
                    ppm: metersPerPixel.map { 1.0 / $0 } ?? 110,
                    nomeDocumento: "marcatura_\(rilievo.sessionId ?? rilievo.id.uuidString)",
                    sessionId: rilievo.sessionId,
                    onChiudi: { showMarcatura = false }
                )
            }
        }
        .fullScreenCover(isPresented: $showEditor3D) {
            // Con sessione: scarica la mesh dal backend; senza: mesh demo.
            if let sid = rilievo.sessionId {
                EditorMesh3DCaricamentoView(sessionId: sid,
                                            onChiudi: { showEditor3D = false })
            } else {
                EditorMesh3DView(onChiudi: { showEditor3D = false })
            }
        }
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
                Button {
                    previewGrandeURL = url
                } label: {
                    ProcessedFacadeImage(url: url)
                }
                .buttonStyle(.plain)
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
            BrandButton(title: "Definisci facciata (4 tap)", systemImage: "viewfinder.rectangular",
                        kind: .primary) {
                showRectifyFacade = true
            }
            .disabled(rilievo.sessionId == nil || stitchedUrl == nil)

            if rectifiedFacadeUrl != nil {
                BrandButton(title: metersPerPixel == nil ? "Imposta scala (2 tap)" :
                                "Scala impostata ✓ — rivedi",
                            systemImage: "ruler", kind: .secondary) {
                    showMeasureScale = true
                }
            }

            BrandButton(title: "Editor 3D mesh (pulizia / piani)", systemImage: "cube.transparent",
                        kind: .secondary) {
                showEditor3D = true
            }

            BrandButton(title: "Segna zone (escluse / da rifare)", systemImage: "square.on.square.dashed",
                        kind: .secondary) {
                showMarcatura = true
            }
            .disabled(stitchedUrl == nil)

            BrandButton(title: "Genera preventivo", systemImage: "doc.text.fill",
                        kind: .ghost) {
                creaPreventivoDaRilievo()
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

private struct ProcessedFacadeImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image.acrobaticaPortraitOriented())
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if failed {
                Text("Panorama non scaricabile")
                    .font(Theme.Typo.body(13))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let ui = UIImage(data: data) else {
                await MainActor.run { failed = true }
                return
            }
            await MainActor.run {
                image = ui
                failed = false
            }
        } catch {
            await MainActor.run { failed = true }
        }
    }
}

private struct FacadeImageFullscreenView: View {
    let url: URL
    let onClose: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        Image(uiImage: image.acrobaticaPortraitOriented())
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    }
                } else if failed {
                    Text("Immagine non scaricabile")
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { onClose() }
                        .foregroundStyle(.white)
                }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let ui = UIImage(data: data) else {
                await MainActor.run { failed = true }
                return
            }
            await MainActor.run {
                image = ui
                failed = false
            }
        } catch {
            await MainActor.run { failed = true }
        }
    }
}

private extension UIImage {
    func acrobaticaPortraitOriented() -> UIImage {
        guard size.width > size.height else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.height, height: size.width),
                                                format: format)
        return renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: size.height / 2, y: size.width / 2)
            cg.rotate(by: .pi / 2)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2,
                            width: size.width, height: size.height))
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
