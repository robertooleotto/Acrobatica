import SwiftUI
import SceneKit
import simd

private enum ModalitaSviluppo: String, CaseIterable, Identifiable {
    case insieme = "Tutto"
    case faccia = "Faccia"
    case aperture = "Aperture"

    var id: String { rawValue }
}

private struct InquadraturaSviluppo: Equatable {
    let chiave: String
    let centro: SIMD2<Float>
    let larghezza: Float
    let altezza: Float
}

/// Area di lavoro separata dall'editor mesh. Mostra lo sviluppo metrico delle
/// facciate usando l'ultimo bundle di piani texturizzati prodotto dal backend.
struct ComputoMetricoView: View {
    let sessionId: String
    let avviaRilevamentoAutomatico: Bool
    let onChiudi: () -> Void
    let onMetricheAggiornate: ((Double, Double) -> Void)?

    @StateObject private var model = ComputoMetricoModel()
    @Environment(\.dismiss) private var dismiss
    @State private var modalita: ModalitaSviluppo = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["DEBUG_COMPUTO_MODE"],
           let mode = ModalitaSviluppo(rawValue: raw) { return mode }
        #endif
        return .insieme
    }()
    @State private var posizioneFaccia = 0
    @State private var aperturaSelezionataID: String?
    @State private var rilevamentoAutomaticoAvviato = false

    init(
        sessionId: String,
        avviaRilevamentoAutomatico: Bool = false,
        onChiudi: @escaping () -> Void,
        onMetricheAggiornate: ((Double, Double) -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.avviaRilevamentoAutomatico = avviaRilevamentoAutomatico
        self.onChiudi = onChiudi
        self.onMetricheAggiornate = onMetricheAggiornate
    }

    var body: some View {
        VStack(spacing: 0) {
            barraSuperiore

            switch model.stato {
            case .caricamento:
                caricamento
            case .errore(let messaggio):
                errore(messaggio)
            case .pronto:
                contenuto
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .task(id: sessionId) {
            await model.carica(sessionId: sessionId)
            guard avviaRilevamentoAutomatico, !rilevamentoAutomaticoAvviato else { return }
            rilevamentoAutomaticoAvviato = true
            modalita = .aperture
            await model.avviaRilevamento(sessionId: sessionId)
        }
        .onChange(of: model.numeroPiani) { numero in
            guard numero > 0, let piani = model.documento?.piani else {
                posizioneFaccia = 0
                return
            }
            posizioneFaccia = piani.indices.max {
                piani[$0].areaM2 < piani[$1].areaM2
            } ?? 0
        }
        .onChange(of: model.areaTotale) { _ in
            onMetricheAggiornate?(model.areaTotale, model.areaNetta)
        }
        .onChange(of: model.areaNetta) { _ in
            onMetricheAggiornate?(model.areaTotale, model.areaNetta)
        }
        .onChange(of: model.aperture.map(\.id)) { ids in
            if let current = aperturaSelezionataID, ids.contains(current) { return }
            aperturaSelezionataID = ids.first
        }
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
                Text(avviaRilevamentoAutomatico ? "Rileva e segna zone" : "Computo metrico")
                    .font(Theme.Typo.title(18))
                    .foregroundStyle(Theme.navy)
                Text(avviaRilevamentoAutomatico ? "Tutte le facciate" : "Sviluppo delle facciate")
                    .font(Theme.Typo.caption(12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()

            Button {
                Task { await model.avviaRilevamento(sessionId: sessionId) }
            } label: {
                Image(systemName: model.rilevamentoAttivo ? "hourglass" : "viewfinder")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.navy)
            .disabled(model.stato != .pronto || model.rilevamentoAttivo)
            .accessibilityLabel("Rileva aperture")

            Button {
                Task { await model.carica(sessionId: sessionId) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.navy)
            .disabled(model.stato == .caricamento)
            .accessibilityLabel("Aggiorna")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.white)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chiudi() {
        dismiss()
        onChiudi()
    }

    private var caricamento: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.navy)
            Text(model.messaggio)
                .font(Theme.Typo.body(14))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errore(_ messaggio: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(Theme.danger)
            Text(messaggio)
                .font(Theme.Typo.body(14))
                .foregroundStyle(Theme.navy)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            BrandButton(title: "Riprova", systemImage: "arrow.clockwise", kind: .secondary) {
                Task { await model.carica(sessionId: sessionId) }
            }
            .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contenuto: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                metrica(label: "Lorda", value: String(format: "%.1f m²", model.areaTotale))
                Divider().frame(height: 42)
                metrica(label: "Aperture", value: String(format: "%.1f m²", model.areaEsclusa))
                Divider().frame(height: 42)
                metrica(label: "Netta", value: String(format: "%.1f m²", model.areaNetta))
                Divider().frame(height: 42)
                metrica(label: "Facce", value: "\(model.numeroPiani)")
            }
            .padding(.vertical, 10)
            .background(Theme.white)

            Picker("Vista", selection: $modalita) {
                ForEach(ModalitaSviluppo.allCases) { modo in
                    Text(modo.rawValue).tag(modo)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.white)

            barraContesto
                .frame(height: 40)
                .background(Theme.white)
                .overlay(alignment: .bottom) { Divider() }

            if let documento = model.documento {
                SviluppoFacciateSceneView(
                    documento: documento,
                    inquadratura: inquadratura(documento),
                    aperturaSelezionataID: modalita == .aperture
                        ? aperturaSelezionataID : nil,
                    attenuaAltreAperture: modalita == .aperture,
                    onAperturaTap: selezionaApertura)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if modalita == .aperture, !model.aperture.isEmpty {
                revisoreAperture
            }
        }
    }

    @ViewBuilder
    private var barraContesto: some View {
        switch modalita {
        case .insieme:
            HStack(spacing: 12) {
                if model.rilevamentoAttivo {
                    ProgressView(value: model.progressoAperture)
                        .frame(width: 72)
                    Text(model.messaggioAperture).lineLimit(1)
                } else {
                    Label("\(model.aperture.count) aperture", systemImage: "rectangle.dashed")
                }
                Spacer()
                Label("Escluse", systemImage: "minus.square.fill")
                    .foregroundStyle(Theme.danger)
                Label("Incluse", systemImage: "plus.square.fill")
                    .foregroundStyle(Theme.success)
            }
            .font(Theme.Typo.caption(11))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 14)

        case .faccia:
            HStack(spacing: 8) {
                pulsanteNavigazione("chevron.left") { cambiaFaccia(-1) }
                Spacer()
                if let piano = pianoSelezionato {
                    VStack(spacing: 1) {
                        Text(piano.nome)
                            .font(Theme.Typo.caption(12, .semibold))
                            .foregroundStyle(Theme.navy)
                            .lineLimit(1)
                        Text(String(
                            format: "%d/%d · %.2f × %.2f m · %.1f m²",
                            posizioneFaccia + 1, model.numeroPiani,
                            piano.larghezzaM, piano.altezzaM, piano.areaM2))
                            .font(Theme.Typo.caption(10))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                Spacer()
                pulsanteNavigazione("chevron.right") { cambiaFaccia(1) }
            }
            .padding(.horizontal, 8)

        case .aperture:
            HStack(spacing: 8) {
                pulsanteNavigazione("chevron.left") { cambiaApertura(-1) }
                Spacer()
                if let apertura = aperturaSelezionata,
                   let posizione = model.aperture.firstIndex(where: { $0.id == apertura.id }) {
                    Label(tipoApertura(apertura.type), systemImage: iconaApertura(apertura.type))
                        .font(Theme.Typo.caption(12, .semibold))
                        .foregroundStyle(Theme.navy)
                    Text("\(posizione + 1)/\(model.aperture.count)")
                        .font(Theme.Typo.mono(10))
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("Nessuna apertura")
                        .font(Theme.Typo.caption(12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                pulsanteNavigazione("chevron.right") { cambiaApertura(1) }
            }
            .padding(.horizontal, 8)
        }
    }

    private var revisoreAperture: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(model.aperture) { apertura in
                            bottoneAnteprima(apertura).id(apertura.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(height: 88)
                .onChange(of: aperturaSelezionataID) { id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            if let apertura = aperturaSelezionata {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.2f m²", apertura.area_m2))
                            .font(Theme.Typo.title(16))
                            .foregroundStyle(Theme.navy)
                        Text("Confidenza \(Int((apertura.confidence * 100).rounded()))% · \(nomePiano(apertura.plane_index))")
                            .font(Theme.Typo.caption(10))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Spacer()
                    Label("Escludi", systemImage: "rectangle.portrait.slash")
                        .font(Theme.Typo.caption(12, .semibold))
                        .foregroundStyle(apertura.excluded ? Theme.danger : Theme.muted)
                    Toggle("", isOn: Binding(
                        get: { apertura.excluded },
                        set: { esclusa in
                            Task {
                                await model.impostaApertura(
                                    id: apertura.id,
                                    esclusa: esclusa,
                                    sessionId: sessionId)
                            }
                        }))
                        .labelsHidden()
                        .tint(Theme.danger)
                        .disabled(model.rilevamentoAttivo)
                }
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(Theme.white)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .background(Theme.white)
        .overlay(alignment: .top) { Divider() }
    }

    private func bottoneAnteprima(
        _ apertura: BackendAPIClient.MetricOpening
    ) -> some View {
        let selezionata = apertura.id == aperturaSelezionataID
        return Button {
            aperturaSelezionataID = apertura.id
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = model.anteprime[apertura.id] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(Theme.grayBg)
                    }
                }
                .frame(width: 68, height: 68)
                .clipped()
                .overlay(alignment: .bottom) {
                    Text(String(format: "%.1f m²", apertura.area_m2))
                        .font(Theme.Typo.mono(9))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 18)
                        .background(.black.opacity(0.68))
                }

                Image(systemName: apertura.excluded ? "minus.square.fill" : "plus.square.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(apertura.excluded ? Theme.danger : Theme.success)
                    .background(Color.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(selezionata ? Theme.yellow : Theme.hair2,
                            lineWidth: selezionata ? 3 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tipoApertura(apertura.type)), \(apertura.area_m2) metri quadrati")
    }

    private func pulsanteNavigazione(
        _ systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.navy)
    }

    private var pianoSelezionato: PianoSviluppato? {
        guard let piani = model.documento?.piani, !piani.isEmpty else { return nil }
        return piani[min(max(posizioneFaccia, 0), piani.count - 1)]
    }

    private var aperturaSelezionata: BackendAPIClient.MetricOpening? {
        guard let id = aperturaSelezionataID else { return model.aperture.first }
        return model.aperture.first(where: { $0.id == id })
    }

    private func cambiaFaccia(_ delta: Int) {
        guard model.numeroPiani > 0 else { return }
        posizioneFaccia = (posizioneFaccia + delta + model.numeroPiani) % model.numeroPiani
    }

    private func cambiaApertura(_ delta: Int) {
        guard !model.aperture.isEmpty else { return }
        let corrente = aperturaSelezionataID.flatMap { id in
            model.aperture.firstIndex(where: { $0.id == id })
        } ?? 0
        let prossimo = (corrente + delta + model.aperture.count) % model.aperture.count
        aperturaSelezionataID = model.aperture[prossimo].id
    }

    private func selezionaApertura(_ id: String) {
        aperturaSelezionataID = id
        modalita = .aperture
    }

    private func inquadratura(
        _ documento: SviluppoFacciateDocumento
    ) -> InquadraturaSviluppo {
        switch modalita {
        case .insieme:
            return documento.inquadraturaCompleta
        case .faccia:
            return pianoSelezionato.map(documento.inquadratura) ?? documento.inquadraturaCompleta
        case .aperture:
            return aperturaSelezionata.flatMap(documento.inquadratura)
                ?? documento.inquadraturaCompleta
        }
    }

    private func tipoApertura(_ type: String) -> String {
        switch type {
        case "window": return "Finestra"
        case "door": return "Porta"
        case "shop_window": return "Vetrina"
        default: return "Apertura"
        }
    }

    private func iconaApertura(_ type: String) -> String {
        switch type {
        case "door": return "door.left.hand.open"
        case "shop_window": return "storefront"
        default: return "rectangle.portrait"
        }
    }

    private func nomePiano(_ indice: Int) -> String {
        model.documento?.piani.first(where: { $0.indice == indice })?.nome
            ?? "Faccia \(indice)"
    }

    private func metrica(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(Theme.Typo.title(16))
                .foregroundStyle(Theme.navy)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(Theme.Typo.caption(11))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
private final class ComputoMetricoModel: ObservableObject {
    enum Stato: Equatable {
        case caricamento
        case pronto
        case errore(String)
    }

    @Published var stato: Stato = .caricamento
    @Published var messaggio = "Scarico i piani texturizzati…"
    @Published var documento: SviluppoFacciateDocumento?
    @Published var areaTotale = 0.0
    @Published var areaEsclusa = 0.0
    @Published var areaNetta = 0.0
    @Published var copertura = 0.0
    @Published var numeroPiani = 0
    @Published var aperture: [BackendAPIClient.MetricOpening] = []
    @Published var anteprime: [String: UIImage] = [:]
    @Published var rilevamentoAttivo = false
    @Published var progressoAperture = 0.0
    @Published var messaggioAperture = ""

    func carica(sessionId: String) async {
        stato = .caricamento
        messaggio = "Scarico i piani texturizzati…"
        documento = nil
        anteprime = [:]
        do {
            let risultato = try await BackendAPIClient.shared.projectionStatus(sessionId: sessionId)
            guard risultato.state == "complete", let main = risultato.main_obj else {
                let dettaglio = risultato.state == "failed" && !risultato.error.isEmpty
                    ? risultato.error
                    : "La proiezione delle texture non è ancora disponibile."
                throw NSError(domain: "ComputoMetrico", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: dettaglio])
            }

            messaggio = "Preparo lo sviluppo delle facciate…"
            let bundle = try await BackendAPIClient.shared.downloadProjectionBundle(
                sessionId: sessionId, files: risultato.files)
            guard let objURL = bundle[main.name] else {
                throw NSError(domain: "ComputoMetrico", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Il bundle non contiene la geometria dei piani."])
            }
            let vecchioBakeConCanaliInvertiti =
                risultato.projection_mode == "oc_reference_registered"
                && risultato.texture_encoding?.lowercased() != "srgb"
            let sviluppo = try SviluppoFacciateBuilder.costruisci(
                objURL: objURL,
                metadati: risultato.planes ?? [],
                correggiRossoBlu: vecchioBakeConCanaliInvertiti)
            documento = sviluppo
            areaTotale = risultato.total_area_m2
            areaNetta = risultato.total_area_m2
            copertura = risultato.coverage
            numeroPiani = sviluppo.numeroPiani
            if let detection = try? await BackendAPIClient.shared.openingStatus(
                sessionId: sessionId) {
                applica(detection)
                if detection.state == "queued" || detection.state == "running" {
                    rilevamentoAttivo = true
                    Task { await attendiRilevamento(sessionId: sessionId) }
                }
            }
            stato = .pronto
        } catch {
            stato = .errore(error.localizedDescription)
        }
    }

    func avviaRilevamento(sessionId: String) async {
        guard !rilevamentoAttivo else { return }
        rilevamentoAttivo = true
        progressoAperture = 0
        messaggioAperture = "Accodo il rilevamento"
        do {
            let result = try await BackendAPIClient.shared.detectOpenings(sessionId: sessionId)
            applica(result)
            await attendiRilevamento(sessionId: sessionId)
        } catch {
            rilevamentoAttivo = false
            messaggioAperture = error.localizedDescription
        }
    }

    func impostaApertura(id: String, esclusa: Bool, sessionId: String) async {
        guard !rilevamentoAttivo,
              let index = aperture.firstIndex(where: { $0.id == id }) else { return }
        guard aperture[index].excluded != esclusa else { return }
        let precedente = aperture
        aperture[index].excluded = esclusa
        aggiornaOverlay()
        do {
            let result = try await BackendAPIClient.shared.reviewOpenings(
                sessionId: sessionId, openings: aperture)
            applica(result)
        } catch {
            aperture = precedente
            aggiornaOverlay()
            messaggioAperture = error.localizedDescription
        }
    }

    private func attendiRilevamento(sessionId: String) async {
        while rilevamentoAttivo && !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
                let result = try await BackendAPIClient.shared.openingStatus(sessionId: sessionId)
                applica(result)
                if result.state == "complete" || result.state == "failed" {
                    rilevamentoAttivo = false
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                messaggioAperture = error.localizedDescription
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func applica(_ result: BackendAPIClient.OpeningDetectionResult) {
        aperture = result.openings
        progressoAperture = result.progress
        messaggioAperture = result.error.isEmpty ? result.message : result.error
        rilevamentoAttivo = result.state == "queued" || result.state == "running"
        if result.state == "complete" {
            areaTotale = result.gross_area_m2
            areaEsclusa = result.excluded_area_m2
            areaNetta = result.net_area_m2
        }
        aggiornaOverlay()
    }

    private func aggiornaOverlay() {
        guard let documento else { return }
        SviluppoFacciateBuilder.aggiornaAperture(aperture, in: documento)
        let ids = Set(aperture.map(\.id))
        if Set(anteprime.keys) != ids {
            anteprime = SviluppoFacciateBuilder.anteprimeAperture(aperture, in: documento)
        }
    }
}

private struct SviluppoFacciateDocumento {
    let scena: SCNScene
    let radice: SCNNode
    let larghezza: Float
    let altezza: Float
    let numeroPiani: Int
    let piani: [PianoSviluppato]
    let texturePiani: [Int: UIImage]
}

private struct PianoSviluppato {
    let indice: Int
    let nome: String
    let origineX: Float
    let origineY: Float
    let larghezza: Float
    let altezza: Float
    let larghezzaM: Double
    let altezzaM: Double
    let areaM2: Double
    let invertiU: Bool
}

private extension SviluppoFacciateDocumento {
    var inquadraturaCompleta: InquadraturaSviluppo {
        InquadraturaSviluppo(
            chiave: "insieme",
            centro: .zero,
            larghezza: larghezza,
            altezza: altezza)
    }

    func inquadratura(_ piano: PianoSviluppato) -> InquadraturaSviluppo {
        InquadraturaSviluppo(
            chiave: "piano-\(piano.indice)",
            centro: SIMD2(
                piano.origineX + piano.larghezza * 0.5 - larghezza * 0.5,
                piano.origineY + piano.altezza * 0.5 - altezza * 0.5),
            larghezza: max(piano.larghezza, 0.1),
            altezza: max(piano.altezza, 0.1))
    }

    func inquadratura(
        _ apertura: BackendAPIClient.MetricOpening
    ) -> InquadraturaSviluppo? {
        guard let piano = piani.first(where: { $0.indice == apertura.plane_index }) else {
            return nil
        }
        let punti = apertura.polygon_uv.compactMap { uv -> SIMD2<Float>? in
            guard uv.count >= 2 else { return nil }
            let u = Float(min(max(uv[0], 0), 1))
            let v = Float(min(max(uv[1], 0), 1))
            return SIMD2(
                piano.origineX + (piano.invertiU ? 1 - u : u) * piano.larghezza,
                piano.origineY + v * piano.altezza)
        }
        guard let minX = punti.map(\.x).min(), let maxX = punti.map(\.x).max(),
              let minY = punti.map(\.y).min(), let maxY = punti.map(\.y).max() else {
            return nil
        }
        let aperturaW = max(maxX - minX, 0.1)
        let aperturaH = max(maxY - minY, 0.1)
        return InquadraturaSviluppo(
            chiave: "apertura-\(apertura.id)",
            centro: SIMD2((minX + maxX) * 0.5 - larghezza * 0.5,
                          (minY + maxY) * 0.5 - altezza * 0.5),
            larghezza: min(max(aperturaW * 3.2, 3.0), max(piano.larghezza, 3.0)),
            altezza: min(max(aperturaH * 3.2, 3.4), max(piano.altezza, 3.4)))
    }
}

private enum SviluppoFacciateBuilder {
    private struct VerticeOBJ: Hashable {
        let posizione: Int
        let texture: Int
    }

    private struct BordoPosizione: Hashable {
        let primo: Int
        let secondo: Int

        init(_ a: Int, _ b: Int) {
            primo = min(a, b)
            secondo = max(a, b)
        }
    }

    private struct GruppoOBJ {
        var nome = ""
        var materiale = ""
        var triangoli: [[VerticeOBJ]] = []
    }

    private struct Piano {
        let indice: Int
        let materiale: String
        let punti: [SIMD3<Float>]
        var uv: [SIMD2<Float>]
        let indici: [Int32]
        var orizzontale: SIMD3<Float>
        let verticale: SIMD3<Float>
        var minX: Float
        var maxX: Float
        let minY: Float
        let maxY: Float
        var invertiU: Bool
        let rettangolare: Bool
    }

    private static func asseEstrusioneCondiviso(
        gruppi: [GruppoOBJ],
        posizioni: [SIMD3<Float>]
    ) -> SIMD3<Float> {
        let gravita = SIMD3<Float>(0, 1, 0)
        var somma = SIMD3<Float>.zero
        var peso: Float = 0

        for gruppo in gruppi {
            var occorrenze: [BordoPosizione: Int] = [:]
            for triangolo in gruppo.triangoli where triangolo.count == 3 {
                for (a, b) in [(0, 1), (1, 2), (2, 0)] {
                    let bordo = BordoPosizione(
                        triangolo[a].posizione, triangolo[b].posizione)
                    occorrenze[bordo, default: 0] += 1
                }
            }
            for (bordo, conteggio) in occorrenze where conteggio == 1 {
                guard posizioni.indices.contains(bordo.primo),
                      posizioni.indices.contains(bordo.secondo) else { continue }
                var direzione = posizioni[bordo.secondo] - posizioni[bordo.primo]
                let lunghezza = simd_length(direzione)
                guard lunghezza > 1e-5 else { continue }
                direzione /= lunghezza
                let verticalita = abs(simd_dot(direzione, gravita))
                guard verticalita >= 0.7 else { continue }
                if simd_dot(direzione, gravita) < 0 { direzione = -direzione }
                somma += direzione * lunghezza
                peso += lunghezza
            }
        }
        guard peso > 1e-5, simd_length(somma) > 1e-5 else { return gravita }
        return simd_normalize(somma)
    }

    static func costruisci(
        objURL: URL,
        metadati: [BackendAPIClient.ProjectionResult.Plane],
        correggiRossoBlu: Bool
    ) throws -> SviluppoFacciateDocumento {
        let testo = try String(contentsOf: objURL, encoding: .utf8)
        var posizioni: [SIMD3<Float>] = []
        var coordinateTexture: [SIMD2<Float>] = []
        var gruppi: [GruppoOBJ] = []
        var corrente = GruppoOBJ()

        func indiceOBJ(_ raw: Int, count: Int) -> Int {
            raw > 0 ? raw - 1 : count + raw
        }
        func riferimento(_ token: Substring) -> VerticeOBJ? {
            let parti = token.split(separator: "/", omittingEmptySubsequences: false)
            guard parti.count >= 2, let vi = Int(parti[0]), let ti = Int(parti[1]) else {
                return nil
            }
            return VerticeOBJ(posizione: indiceOBJ(vi, count: posizioni.count),
                              texture: indiceOBJ(ti, count: coordinateTexture.count))
        }
        func salvaCorrente() {
            if !corrente.triangoli.isEmpty { gruppi.append(corrente) }
        }

        for riga in testo.split(whereSeparator: \Character.isNewline) {
            let parti = riga.split(whereSeparator: \Character.isWhitespace)
            guard let comando = parti.first else { continue }
            switch comando {
            case "v" where parti.count >= 4:
                if let x = Float(parti[1]), let y = Float(parti[2]), let z = Float(parti[3]) {
                    posizioni.append(SIMD3(x, y, z))
                }
            case "vt" where parti.count >= 3:
                if let u = Float(parti[1]), let v = Float(parti[2]) {
                    coordinateTexture.append(SIMD2(u, v))
                }
            case "o" where parti.count >= 2,
                 "g" where parti.count >= 2:
                salvaCorrente()
                corrente = GruppoOBJ(nome: String(parti[1]))
            case "usemtl" where parti.count >= 2:
                corrente.materiale = String(parti[1])
            case "f" where parti.count >= 4:
                let faccia = parti.dropFirst().compactMap(riferimento)
                guard faccia.count >= 3 else { continue }
                for i in 1..<(faccia.count - 1) {
                    corrente.triangoli.append([faccia[0], faccia[i], faccia[i + 1]])
                }
            default:
                continue
            }
        }
        salvaCorrente()

        let up = SIMD3<Float>(0, 1, 0)
        let asseEstrusione = asseEstrusioneCondiviso(
            gruppi: gruppi, posizioni: posizioni)
        var piani: [Piano] = []
        for gruppo in gruppi {
            var mappa: [VerticeOBJ: Int32] = [:]
            var punti: [SIMD3<Float>] = []
            var uv: [SIMD2<Float>] = []
            var indici: [Int32] = []
            for riferimento in gruppo.triangoli.flatMap({ $0 }) {
                guard posizioni.indices.contains(riferimento.posizione),
                      coordinateTexture.indices.contains(riferimento.texture) else { continue }
                if let indice = mappa[riferimento] {
                    indici.append(indice)
                } else {
                    let indice = Int32(punti.count)
                    mappa[riferimento] = indice
                    punti.append(posizioni[riferimento.posizione])
                    uv.append(coordinateTexture[riferimento.texture])
                    indici.append(indice)
                }
            }
            guard punti.count >= 3, indici.count >= 3 else { continue }

            let a = punti[Int(indici[0])]
            let b = punti[Int(indici[1])]
            let c = punti[Int(indici[2])]
            var normale = simd_cross(b - a, c - a)
            guard simd_length(normale) > 1e-6 else { continue }
            normale = simd_normalize(normale)

            // I piani sono generati estrudendo lo stesso perimetro. L'asse
            // condiviso include l'eventuale inclinazione reale della facciata;
            // usarlo evita che le spallette diventino trapezi nello sviluppo.
            var verticale = asseEstrusione
                - normale * simd_dot(asseEstrusione, normale)
            if simd_length(verticale) < 0.2 {
                verticale = up - normale * simd_dot(up, normale)
            }
            if simd_length(verticale) < 0.2 { verticale = b - a }
            guard simd_length(verticale) > 1e-6 else { continue }
            verticale = simd_normalize(verticale)
            var orizzontale = simd_cross(normale, verticale)
            guard simd_length(orizzontale) > 1e-6 else { continue }
            orizzontale = simd_normalize(orizzontale)

            let mediaU = uv.reduce(Float(0)) { $0 + $1.x } / Float(uv.count)
            let mediaX = punti.reduce(Float(0)) { $0 + simd_dot($1, orizzontale) }
                / Float(punti.count)
            let covarianza = zip(punti, uv).reduce(Float(0)) { parziale, coppia in
                parziale + (simd_dot(coppia.0, orizzontale) - mediaX) * (coppia.1.x - mediaU)
            }
            if covarianza < 0 { orizzontale = -orizzontale }

            let xs = punti.map { simd_dot($0, orizzontale) }
            let ys = punti.map { simd_dot($0, verticale) }
            let identificatore = gruppo.nome.isEmpty ? gruppo.materiale : gruppo.nome
            let componenti = identificatore.split(separator: "_")
            let indice = componenti.count > 1 ? Int(componenti[1]) ?? Int.max : Int.max
            piani.append(Piano(
                indice: indice, materiale: gruppo.materiale, punti: punti,
                uv: uv, indici: indici, orizzontale: orizzontale, verticale: verticale,
                minX: xs.min() ?? 0, maxX: xs.max() ?? 0,
                minY: ys.min() ?? 0, maxY: ys.max() ?? 0,
                invertiU: false,
                rettangolare: punti.count == 4
                    && identificatore.lowercased().contains("spalletta")))
        }
        piani.sort { $0.indice < $1.indice }
        guard !piani.isEmpty else {
            throw NSError(domain: "ComputoMetrico", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Non sono stati trovati piani validi nello sviluppo."])
        }

        for indice in 1..<piani.count {
            let precedente = piani[indice - 1]
            let corrente = piani[indice]
            let destraPrecedente = centroBordo(precedente.punti,
                                               asse: precedente.orizzontale,
                                               estremoMassimo: true)
            let sinistraDiretta = centroBordo(corrente.punti,
                                              asse: corrente.orizzontale,
                                              estremoMassimo: false)
            let sinistraInvertita = centroBordo(corrente.punti,
                                                asse: corrente.orizzontale,
                                                estremoMassimo: true)
            if simd_distance(destraPrecedente, sinistraInvertita) + 1e-4
                < simd_distance(destraPrecedente, sinistraDiretta) {
                piani[indice].orizzontale = -corrente.orizzontale
                piani[indice].minX = -corrente.maxX
                piani[indice].maxX = -corrente.minX
                // Il ribaltamento geometrico apre rigidamente il piano attorno
                // allo spigolo condiviso. Le UV restano legate ai loro vertici:
                // invertirle qui specchierebbe una seconda volta la texture.
                piani[indice].invertiU = true
            }
        }

        let minYGlobale = piani.map(\.minY).min() ?? 0
        let maxYGlobale = piani.map(\.maxY).max() ?? 0
        let scena = SCNScene()
        let radice = SCNNode()
        radice.name = "sviluppo-facciate"
        scena.rootNode.addChildNode(radice)
        var cursoreX: Float = 0
        var pianiSviluppati: [PianoSviluppato] = []
        var texturePiani: [Int: UIImage] = [:]
        let metadatiPerIndice = Dictionary(
            uniqueKeysWithValues: metadati.map { ($0.index, $0) })

        for piano in piani {
            let larghezzaPiano = max(piano.maxX - piano.minX, 0)
            let altezzaPiano = max(piano.maxY - piano.minY, 0)
            let meta = metadatiPerIndice[piano.indice]
            pianiSviluppati.append(PianoSviluppato(
                indice: piano.indice,
                nome: meta?.nome ?? "Faccia \(piano.indice)",
                origineX: cursoreX,
                origineY: piano.minY - minYGlobale,
                larghezza: larghezzaPiano,
                altezza: altezzaPiano,
                larghezzaM: meta?.width_m ?? Double(larghezzaPiano),
                altezzaM: meta?.height_m ?? Double(altezzaPiano),
                areaM2: meta?.area_m2 ?? Double(larghezzaPiano * altezzaPiano),
                invertiU: piano.invertiU))
            let sviluppati = piano.punti.map { punto -> SCNVector3 in
                let localeX = simd_dot(punto, piano.orizzontale) - piano.minX
                let localeY = simd_dot(punto, piano.verticale) - piano.minY
                let x: Float
                let y: Float
                if piano.rettangolare {
                    // La saldatura fra piani stimati puo lasciare uno shear
                    // residuo. Nel computo una spalletta a quattro vertici
                    // segue la regola architettonica rettangolare.
                    x = cursoreX + (localeX < larghezzaPiano * 0.5 ? 0 : larghezzaPiano)
                    y = piano.minY - minYGlobale
                        + (localeY < altezzaPiano * 0.5 ? 0 : altezzaPiano)
                } else {
                    x = cursoreX + localeX
                    y = piano.minY - minYGlobale + localeY
                }
                return SCNVector3(x, y, 0)
            }
            let sorgenteVertici = SCNGeometrySource(vertices: sviluppati)
            let sorgenteUV = SCNGeometrySource(textureCoordinates: piano.uv.map {
                // Le UV OBJ hanno origine in basso a sinistra, UIImage in alto.
                CGPoint(x: CGFloat($0.x), y: CGFloat(1 - $0.y))
            })
            let elemento = SCNGeometryElement(indices: piano.indici, primitiveType: .triangles)
            let geometria = SCNGeometry(sources: [sorgenteVertici, sorgenteUV],
                                        elements: [elemento])
            let materiale = SCNMaterial()
            materiale.name = piano.materiale
            let immagineURL = objURL.deletingLastPathComponent()
                .appendingPathComponent("\(piano.materiale).png")
            guard let immagine = UIImage(contentsOfFile: immagineURL.path) else {
                throw NSError(domain: "ComputoMetrico", code: 4,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Texture mancante per \(piano.materiale)."])
            }
            texturePiani[piano.indice] = immagine
            if correggiRossoBlu {
                // Correzione GPU per i vecchi bake: evita di ricodificare tutte
                // le texture sul main thread durante l'apertura della schermata.
                materiale.shaderModifiers = [
                    .fragment: "#pragma body\n_output.color = _output.color.bgra;"
                ]
            }
            materiale.diffuse.contents = immagine
            materiale.diffuse.magnificationFilter = .linear
            materiale.diffuse.minificationFilter = .linear
            materiale.lightingModel = .constant
            materiale.isDoubleSided = true
            geometria.materials = [materiale]
            let nodo = SCNNode(geometry: geometria)
            nodo.name = "piano-\(piano.indice)"
            radice.addChildNode(nodo)
            cursoreX += larghezzaPiano
        }

        let altezza = max(maxYGlobale - minYGlobale, 0.01)
        radice.simdPosition = SIMD3(-cursoreX * 0.5, -altezza * 0.5, 0)
        return SviluppoFacciateDocumento(scena: scena, radice: radice,
                                         larghezza: max(cursoreX, 0.01),
                                         altezza: altezza,
                                         numeroPiani: piani.count,
                                         piani: pianiSviluppati,
                                         texturePiani: texturePiani)
    }

    static func aggiornaAperture(
        _ aperture: [BackendAPIClient.MetricOpening],
        in documento: SviluppoFacciateDocumento
    ) {
        documento.radice.childNode(withName: "aperture-overlay", recursively: false)?
            .removeFromParentNode()
        guard !aperture.isEmpty else { return }
        let contenitore = SCNNode()
        contenitore.name = "aperture-overlay"
        documento.radice.addChildNode(contenitore)

        let piani = Dictionary(uniqueKeysWithValues: documento.piani.map { ($0.indice, $0) })
        for apertura in aperture {
            guard let piano = piani[apertura.plane_index], apertura.polygon_uv.count >= 3 else {
                continue
            }
            let punti = apertura.polygon_uv.compactMap { uv -> CGPoint? in
                guard uv.count >= 2 else { return nil }
                let u = Float(min(max(uv[0], 0), 1))
                let v = Float(min(max(uv[1], 0), 1))
                let x = piano.origineX + (piano.invertiU ? 1 - u : u) * piano.larghezza
                let y = piano.origineY + v * piano.altezza
                return CGPoint(x: CGFloat(x), y: CGFloat(y))
            }
            guard punti.count >= 3 else { continue }

            let path = UIBezierPath()
            path.move(to: punti[0])
            for punto in punti.dropFirst() { path.addLine(to: punto) }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: 0.002)
            shape.chamferRadius = 0
            let material = SCNMaterial()
            let color = apertura.excluded
                ? UIColor(red: 0.85, green: 0.20, blue: 0.17, alpha: 1)
                : UIColor(red: 0.12, green: 0.62, blue: 0.45, alpha: 1)
            material.name = apertura.excluded ? "stato-esclusa" : "stato-inclusa"
            material.diffuse.contents = color.withAlphaComponent(0.42)
            material.emission.contents = color.withAlphaComponent(0.22)
            material.lightingModel = .constant
            material.isDoubleSided = true
            shape.materials = [material]
            let nodo = SCNNode(geometry: shape)
            nodo.name = "apertura-\(apertura.id)"
            nodo.position.z = 0.02

            let verticiLinea = punti.map { SCNVector3(Float($0.x), Float($0.y), 0) }
            let sorgenteLinea = SCNGeometrySource(vertices: verticiLinea)
            var indiciLinea: [Int32] = []
            for index in punti.indices {
                indiciLinea.append(Int32(index))
                indiciLinea.append(Int32((index + 1) % punti.count))
            }
            let elementoLinea = SCNGeometryElement(
                indices: indiciLinea,
                primitiveType: .line)
            let geometriaLinea = SCNGeometry(
                sources: [sorgenteLinea], elements: [elementoLinea])
            let materialeLinea = SCNMaterial()
            materialeLinea.name = material.name
            materialeLinea.diffuse.contents = color
            materialeLinea.emission.contents = color
            materialeLinea.lightingModel = .constant
            geometriaLinea.materials = [materialeLinea]
            let linea = SCNNode(geometry: geometriaLinea)
            linea.position.z = 0.004
            nodo.addChildNode(linea)
            contenitore.addChildNode(nodo)
        }
    }

    static func evidenziaApertura(
        _ id: String?,
        attenuaAltre: Bool,
        in documento: SviluppoFacciateDocumento
    ) {
        guard let contenitore = documento.radice.childNode(
            withName: "aperture-overlay", recursively: false) else { return }
        for nodo in contenitore.childNodes {
            guard let name = nodo.name, name.hasPrefix("apertura-") else { continue }
            let selected = id.map { name == "apertura-\($0)" } ?? false
            let stateName = nodo.geometry?.firstMaterial?.name ?? "stato-esclusa"
            let base = stateName == "stato-inclusa"
                ? UIColor(red: 0.12, green: 0.62, blue: 0.45, alpha: 1)
                : UIColor(red: 0.85, green: 0.20, blue: 0.17, alpha: 1)
            let color = selected
                ? UIColor(red: 0.96, green: 0.82, blue: 0.05, alpha: 1)
                : base
            nodo.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(
                selected ? 0.64 : 0.42)
            nodo.geometry?.firstMaterial?.emission.contents = color.withAlphaComponent(
                selected ? 0.48 : 0.22)
            nodo.childNodes.first?.geometry?.firstMaterial?.diffuse.contents = color
            nodo.childNodes.first?.geometry?.firstMaterial?.emission.contents = color
            nodo.opacity = attenuaAltre && id != nil && !selected ? 0.28 : 1
            nodo.position.z = selected ? 0.05 : 0.02
        }
    }

    static func anteprimeAperture(
        _ aperture: [BackendAPIClient.MetricOpening],
        in documento: SviluppoFacciateDocumento
    ) -> [String: UIImage] {
        var result: [String: UIImage] = [:]
        for apertura in aperture {
            guard let image = documento.texturePiani[apertura.plane_index],
                  let cgImage = image.cgImage else { continue }
            let uv = apertura.polygon_uv.filter { $0.count >= 2 }
            guard let minU = uv.map({ $0[0] }).min(), let maxU = uv.map({ $0[0] }).max(),
                  let minV = uv.map({ $0[1] }).min(), let maxV = uv.map({ $0[1] }).max()
            else { continue }

            let paddingU = max((maxU - minU) * 0.12, 0.01)
            let paddingV = max((maxV - minV) * 0.12, 0.01)
            let left = min(max(minU - paddingU, 0), 1)
            let right = min(max(maxU + paddingU, 0), 1)
            let bottom = min(max(minV - paddingV, 0), 1)
            let top = min(max(maxV + paddingV, 0), 1)
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            let crop = CGRect(
                x: CGFloat(left) * width,
                y: CGFloat(1 - top) * height,
                width: CGFloat(right - left) * width,
                height: CGFloat(top - bottom) * height)
                .integral
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard crop.width >= 2, crop.height >= 2,
                  let cropped = cgImage.cropping(to: crop) else { continue }
            result[apertura.id] = UIImage(cgImage: cropped, scale: image.scale,
                                          orientation: .up)
        }
        return result
    }

    private static func centroBordo(
        _ punti: [SIMD3<Float>], asse: SIMD3<Float>, estremoMassimo: Bool
    ) -> SIMD3<Float> {
        let valori = punti.map { simd_dot($0, asse) }
        guard let minimo = valori.min(), let massimo = valori.max() else { return .zero }
        let target = estremoMassimo ? massimo : minimo
        let tolleranza = max((massimo - minimo) * 0.02, 1e-5)
        let bordo = zip(punti, valori).compactMap {
            abs($0.1 - target) <= tolleranza ? $0.0 : nil
        }
        return bordo.reduce(.zero, +) / Float(max(bordo.count, 1))
    }
}

private struct SviluppoFacciateSceneView: UIViewRepresentable {
    let documento: SviluppoFacciateDocumento
    let inquadratura: InquadraturaSviluppo
    let aperturaSelezionataID: String?
    let attenuaAltreAperture: Bool
    let onAperturaTap: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = UIColor(red: 0.075, green: 0.082, blue: 0.09, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        context.coordinator.onAperturaTap = onAperturaTap
        context.coordinator.inquadratura = inquadratura
        context.coordinator.installa(in: view, documento: documento)
        SviluppoFacciateBuilder.evidenziaApertura(
            aperturaSelezionataID,
            attenuaAltre: attenuaAltreAperture,
            in: documento)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== documento.scena {
            context.coordinator.installa(in: view, documento: documento)
        } else {
            context.coordinator.documento = documento
        }
        context.coordinator.onAperturaTap = onAperturaTap
        context.coordinator.inquadratura = inquadratura
        SviluppoFacciateBuilder.evidenziaApertura(
            aperturaSelezionataID,
            attenuaAltre: attenuaAltreAperture,
            in: documento)
        DispatchQueue.main.async { context.coordinator.inquadra(inquadratura) }
    }

    final class Coordinator: NSObject {
        weak var view: SCNView?
        var documento: SviluppoFacciateDocumento?
        var onAperturaTap: ((String) -> Void)?
        var inquadratura = InquadraturaSviluppo(
            chiave: "insieme", centro: .zero, larghezza: 1, altezza: 1)
        private var ultimaDimensione: CGSize = .zero
        private var ultimaInquadratura = ""

        func installa(in view: SCNView, documento: SviluppoFacciateDocumento) {
            self.view = view
            self.documento = documento
            view.scene = documento.scena

            let cameraNode = SCNNode()
            cameraNode.name = "camera-computo"
            let camera = SCNCamera()
            camera.usesOrthographicProjection = true
            camera.zNear = 0.01
            camera.zFar = 10_000
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0, 100)
            documento.scena.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode

            if view.gestureRecognizers?.isEmpty != false {
                let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
                let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
                pan.minimumNumberOfTouches = 1
                pan.maximumNumberOfTouches = 2
                let doppioTap = UITapGestureRecognizer(target: self, action: #selector(reset(_:)))
                doppioTap.numberOfTapsRequired = 2
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapApertura(_:)))
                tap.require(toFail: doppioTap)
                view.addGestureRecognizer(pinch)
                view.addGestureRecognizer(pan)
                view.addGestureRecognizer(doppioTap)
                view.addGestureRecognizer(tap)
            }
            DispatchQueue.main.async { self.inquadra(self.inquadratura, forzato: true) }
        }

        func inquadra(
            _ target: InquadraturaSviluppo,
            forzato: Bool = false
        ) {
            guard let view, view.bounds.width > 0, view.bounds.height > 0,
                  let camera = view.pointOfView?.camera else { return }
            if !forzato, view.bounds.size == ultimaDimensione,
               target.chiave == ultimaInquadratura { return }
            ultimaDimensione = view.bounds.size
            ultimaInquadratura = target.chiave
            let rapporto = Float(view.bounds.width / view.bounds.height)
            let scala = max(target.altezza * 0.62,
                            target.larghezza / max(rapporto, 0.01) * 0.62)
            camera.orthographicScale = Double(max(scala, 0.1))
            view.pointOfView?.position = SCNVector3(
                target.centro.x, target.centro.y, 100)
        }

        @objc private func pinch(_ gesto: UIPinchGestureRecognizer) {
            guard let camera = view?.pointOfView?.camera else { return }
            camera.orthographicScale = max(0.05, camera.orthographicScale / Double(gesto.scale))
            gesto.scale = 1
        }

        @objc private func pan(_ gesto: UIPanGestureRecognizer) {
            guard let view, let cameraNode = view.pointOfView,
                  let camera = cameraNode.camera, view.bounds.height > 0 else { return }
            let spostamento = gesto.translation(in: view)
            let metriPerPixel = camera.orthographicScale / Double(view.bounds.height)
            cameraNode.position.x -= Float(Double(spostamento.x) * metriPerPixel)
            cameraNode.position.y += Float(Double(spostamento.y) * metriPerPixel)
            gesto.setTranslation(.zero, in: view)
        }

        @objc private func tapApertura(_ gesto: UITapGestureRecognizer) {
            guard gesto.state == .ended, let view else { return }
            let punto = gesto.location(in: view)
            for hit in view.hitTest(punto, options: [
                SCNHitTestOption.firstFoundOnly: true,
                SCNHitTestOption.ignoreHiddenNodes: true,
            ]) {
                var nodo: SCNNode? = hit.node
                while let corrente = nodo {
                    if let nome = corrente.name, nome.hasPrefix("apertura-") {
                        onAperturaTap?(String(nome.dropFirst("apertura-".count)))
                        return
                    }
                    nodo = corrente.parent
                }
            }
        }

        @objc private func reset(_ gesto: UITapGestureRecognizer) {
            inquadra(inquadratura, forzato: true)
        }
    }
}
