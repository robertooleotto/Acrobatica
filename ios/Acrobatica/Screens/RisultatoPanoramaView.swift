import SwiftUI

private struct TexturePianoCopertina {
    let url: URL
    let piano: BackendAPIClient.ProjectionResult.Plane
}

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
    @State private var showFiniture = false        // proposte colore/finitura intonaco
    @State private var showComputoMetrico = false  // sviluppo 2D e superfici dei piani
    @State private var rectifiedFacadeUrl: URL?
    @State private var metersPerPixel: Double?
    @State private var orthoComposite: URL?
    @State private var errore: String?
    @State private var previewGrandeURL: URL?
    @State private var previewGrandeRuotaInVerticale = true
    @State private var textureCopertina: TexturePianoCopertina?
    @State private var pipeline3DInCorso = false
    @State private var pipeline3DFallita = false
    @State private var pipeline3DProgresso = 0.0
    @State private var pipeline3DMessaggio = ""
    @State private var risultato3DAperto = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                panoramaCard
                metriche
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
        .task(id: rilievo.sessionId) { await osservaPipeline3D() }
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
                FacadeImageFullscreenView(
                    url: url,
                    ruotaInVerticale: previewGrandeRuotaInVerticale
                ) {
                    previewGrandeURL = nil
                }
            }
        }
        .fullScreenCover(isPresented: $showMarcatura) {
            if let url = textureCopertina?.url ?? stitchedUrl {
                MarcaturaFacciataCaricamentoView(
                    url: url,
                    ppm: metersPerPixel.map { 1.0 / $0 } ?? 110,
                    nomeDocumento: nomeDocumentoZone,
                    sessionId: rilievo.sessionId,
                    planeIndex: textureCopertina?.piano.index,
                    metriLarghezza: textureCopertina?.piano.width_m,
                    metriAltezza: textureCopertina?.piano.height_m,
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
        .fullScreenCover(isPresented: $showFiniture) {
            ProposteFinituraView(
                referenceURL: textureCopertina?.url ?? stitchedUrl,
                onChiudi: { showFiniture = false }
            )
        }
        .fullScreenCover(isPresented: $showComputoMetrico) {
            if let sid = rilievo.sessionId {
                ComputoMetricoView(sessionId: sid,
                                   onChiudi: { showComputoMetrico = false })
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
            if let url = textureCopertina?.url {
                Button {
                    previewGrandeRuotaInVerticale = false
                    previewGrandeURL = url
                } label: {
                    FacadeCoverImage(url: url)
                }
                .buttonStyle(.plain)
            } else if elaborazioneInCorso {
                VStack(spacing: 8) {
                    ProgressView().tint(Theme.navy)
                    Text("Elaborazione (stitch + keystone)…")
                        .font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if let url = stitchedUrl {
                Button {
                    previewGrandeRuotaInVerticale = true
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
        }
    }

    private func areaString(_ m2: Double) -> String {
        m2 > 0 ? String(format: "%.1f m²", m2) : "—"
    }

    // MARK: – Action buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if pipeline3DInCorso || !pipeline3DMessaggio.isEmpty {
                HStack(spacing: 10) {
                    if pipeline3DInCorso {
                        ProgressView(value: pipeline3DProgresso)
                            .frame(width: 64)
                    } else if pipeline3DFallita {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                    }
                    Text(pipeline3DMessaggio)
                        .font(Theme.Typo.caption(12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.vertical, 6)
            }

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

            BrandButton(title: "Simula finitura", systemImage: "paintbrush.pointed.fill",
                        kind: .secondary) {
                showFiniture = true
            }
            .disabled(textureCopertina == nil && stitchedUrl == nil)

            BrandButton(title: "Rileva e segna zone", systemImage: "viewfinder",
                        kind: .secondary) {
                showMarcatura = true
            }
            .disabled(textureCopertina == nil && stitchedUrl == nil)

            BrandButton(title: "Computo metrico", systemImage: "ruler",
                        kind: .secondary) {
                showComputoMetrico = true
            }
            .disabled(rilievo.sessionId == nil)

            BrandButton(title: "Genera preventivo", systemImage: "doc.text.fill",
                        kind: .ghost) {
                creaPreventivoDaRilievo()
            }
        }
    }

    @MainActor
    private func osservaPipeline3D() async {
        guard let sid = rilievo.sessionId else { return }
        while !Task.isCancelled {
            do {
                let result = try await BackendAPIClient.shared.projectionStatus(
                    sessionId: sid)
                switch result.state {
                case "complete":
                    pipeline3DInCorso = false
                    pipeline3DFallita = false
                    pipeline3DProgresso = 1
                    pipeline3DMessaggio = "Modello 3D texturizzato pronto"
                    await aggiornaCopertinaTexture(from: result)
                    rilievo.areaLorda = result.total_area_m2
                    if !risultato3DAperto {
                        risultato3DAperto = true
                        showEditor3D = true
                    }
                    return
                case "failed":
                    pipeline3DInCorso = false
                    pipeline3DFallita = true
                    pipeline3DMessaggio = result.error.isEmpty
                        ? "Elaborazione 3D non riuscita" : result.error
                    return
                case "queued", "running":
                    pipeline3DInCorso = true
                    pipeline3DFallita = false
                    pipeline3DProgresso = result.progress
                    pipeline3DMessaggio = result.message
                default:
                    pipeline3DInCorso = true
                    pipeline3DFallita = false
                    pipeline3DProgresso = 0
                    pipeline3DMessaggio = "Attendo il modello 3D dal Mac"
                }
            } catch {
                pipeline3DInCorso = true
                pipeline3DFallita = false
                pipeline3DMessaggio = "Connessione al calcolo 3D in attesa"
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func copertinaTexture(
        from risultato: BackendAPIClient.ProjectionResult
    ) -> TexturePianoCopertina? {
        guard let piano = risultato.planes?.max(by: { $0.area_m2 < $1.area_m2 }) else {
            return nil
        }
        let nome = URL(fileURLWithPath: piano.file).lastPathComponent
        guard let file = risultato.files.first(where: {
            $0.name == piano.file
                || URL(fileURLWithPath: $0.name).lastPathComponent == nome
        }) else { return nil }
        guard let url = URL(string: file.url) else { return nil }
        return TexturePianoCopertina(url: url, piano: piano)
    }

    @MainActor
    private func aggiornaCopertinaTexture(
        from risultato: BackendAPIClient.ProjectionResult
    ) async {
        guard let remota = copertinaTexture(from: risultato),
              let sessionId = rilievo.sessionId else {
            textureCopertina = copertinaTexture(from: risultato)
            return
        }
        do {
            let bundle = try await BackendAPIClient.shared.downloadProjectionBundle(
                sessionId: sessionId, files: risultato.files)
            let nome = URL(fileURLWithPath: remota.piano.file).lastPathComponent
            let locale = bundle[remota.piano.file] ?? bundle.first(where: {
                URL(fileURLWithPath: $0.key).lastPathComponent == nome
            })?.value
            textureCopertina = TexturePianoCopertina(
                url: locale ?? remota.url, piano: remota.piano)
        } catch {
            textureCopertina = remota
        }
    }

    private var nomeDocumentoZone: String {
        let base = rilievo.sessionId ?? rilievo.id.uuidString
        guard let indice = textureCopertina?.piano.index else {
            return "marcatura_\(base)"
        }
        return "marcatura_\(base)_p\(indice)"
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
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (remoteData, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                data = remoteData
            }
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

/// Texture ortogonale del piano principale, usata come immagine di copertina.
private struct FacadeCoverImage: View {
    let url: URL
    var height: CGFloat = 220
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(Theme.navy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Theme.grayBg)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: url) { await load() }
    }

    private func load() async {
        do {
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (remoteData, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                data = remoteData
            }
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
    let ruotaInVerticale: Bool
    let onClose: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        Image(uiImage: ruotaInVerticale
                              ? image.acrobaticaPortraitOriented() : image)
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
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (remoteData, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                data = remoteData
            }
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

private enum TipoFinituraIntonaco: String, CaseIterable, Identifiable {
    case liscio = "Liscio"
    case civile = "Civile fine"
    case minerale = "Minerale"

    var id: String { rawValue }
    var intensita: Double {
        switch self {
        case .liscio: return 0.20
        case .civile: return 0.16
        case .minerale: return 0.12
        }
    }
}

private enum ColoreFinitura: String, CaseIterable, Identifiable {
    case originale = "Originale"
    case bianco = "Bianco"
    case avorio = "Avorio"
    case grigio = "Grigio chiaro"
    case giallo = "Giallo tenue"
    case rosa = "Rosa tenue"

    var id: String { rawValue }
    var colore: Color? {
        switch self {
        case .originale: return nil
        case .bianco: return Color(hex: 0xF1F1EC)
        case .avorio: return Color(hex: 0xDDD7C7)
        case .grigio: return Color(hex: 0xAEB4B7)
        case .giallo: return Color(hex: 0xD9BF6C)
        case .rosa: return Color(hex: 0xC89A91)
        }
    }
}

private struct ProposteFinituraView: View {
    let referenceURL: URL?
    let onChiudi: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var finitura: TipoFinituraIntonaco = .liscio
    @State private var colore: ColoreFinitura = .originale

    var body: some View {
        VStack(spacing: 0) {
            barraSuperiore
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    anteprima

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Finitura intonaco")
                            .font(Theme.Typo.caption(12, .semibold))
                            .foregroundStyle(Theme.muted)
                        Menu {
                            ForEach(TipoFinituraIntonaco.allCases) { tipo in
                                Button {
                                    finitura = tipo
                                } label: {
                                    Label(tipo.rawValue,
                                          systemImage: finitura == tipo ? "checkmark" : "circle")
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "paintbrush.pointed")
                                Text(finitura.rawValue)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .font(Theme.Typo.body(15, .semibold))
                            .foregroundStyle(Theme.navy)
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(Theme.white,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.hair2, lineWidth: 1))
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Colore")
                            .font(Theme.Typo.caption(12, .semibold))
                            .foregroundStyle(Theme.muted)
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 8),
                                count: ColoreFinitura.allCases.count),
                            spacing: 8
                        ) {
                            ForEach(ColoreFinitura.allCases) { campione in
                                Button {
                                    colore = campione
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(campione.colore ?? Theme.white)
                                        if campione == .originale {
                                            Image(systemName: "circle.slash")
                                                .font(.system(size: 19, weight: .medium))
                                                .foregroundStyle(Theme.muted)
                                        } else if colore == campione {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(Theme.navy)
                                        }
                                    }
                                    .frame(width: 38, height: 38)
                                    .overlay(Circle().stroke(
                                        colore == campione ? Theme.navy : Theme.hair2,
                                        lineWidth: colore == campione ? 2 : 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(campione.rawValue)
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.paper.ignoresSafeArea())
    }

    private var barraSuperiore: some View {
        HStack(spacing: 12) {
            Button(action: chiudi) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.navy)
            .accessibilityLabel("Chiudi")

            VStack(alignment: .leading, spacing: 1) {
                Text("Proposte di finitura")
                    .font(Theme.Typo.title(18))
                    .foregroundStyle(Theme.navy)
                Text("Intonaco")
                    .font(Theme.Typo.caption(12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.white)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var anteprima: some View {
        ZStack {
            if let referenceURL {
                FacadeCoverImage(url: referenceURL, height: 330)
            } else {
                Image(systemName: "building.2")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 330)
                    .background(Theme.grayBg)
            }
            if let tinta = colore.colore {
                tinta
                    .opacity(finitura.intensita)
                    .blendMode(.color)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 330)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func chiudi() {
        dismiss()
        onChiudi()
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
