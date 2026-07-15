import SwiftUI
import SceneKit
import simd

/// Area di lavoro separata dall'editor mesh. Mostra lo sviluppo metrico delle
/// facciate usando l'ultimo bundle di piani texturizzati prodotto dal backend.
struct ComputoMetricoView: View {
    let sessionId: String
    let onChiudi: () -> Void

    @StateObject private var model = ComputoMetricoModel()
    @Environment(\.dismiss) private var dismiss

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
        .task(id: sessionId) { await model.carica(sessionId: sessionId) }
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
                Text("Computo metrico")
                    .font(Theme.Typo.title(18))
                    .foregroundStyle(Theme.navy)
                Text("Sviluppo delle facciate")
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

            HStack(spacing: 12) {
                if model.rilevamentoAttivo {
                    ProgressView(value: model.progressoAperture)
                        .frame(width: 72)
                    Text(model.messaggioAperture)
                        .lineLimit(1)
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
            .frame(height: 36)
            .background(Theme.white)
            .overlay(alignment: .bottom) { Divider() }

            if let documento = model.documento {
                SviluppoFacciateSceneView(
                    documento: documento,
                    onAperturaTap: { id in
                        Task { await model.invertiApertura(id: id, sessionId: sessionId) }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
    @Published var rilevamentoAttivo = false
    @Published var progressoAperture = 0.0
    @Published var messaggioAperture = ""

    func carica(sessionId: String) async {
        stato = .caricamento
        messaggio = "Scarico i piani texturizzati…"
        documento = nil
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
            let bundle = try await BackendAPIClient.shared.downloadMeshBundle(risultato.files)
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

    func invertiApertura(id: String, sessionId: String) async {
        guard !rilevamentoAttivo,
              let index = aperture.firstIndex(where: { $0.id == id }) else { return }
        let precedente = aperture
        aperture[index].excluded.toggle()
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
    }
}

private struct SviluppoFacciateDocumento {
    let scena: SCNScene
    let radice: SCNNode
    let larghezza: Float
    let altezza: Float
    let numeroPiani: Int
    let piani: [PianoSviluppato]
}

private struct PianoSviluppato {
    let indice: Int
    let origineX: Float
    let origineY: Float
    let larghezza: Float
    let altezza: Float
    let invertiU: Bool
}

private enum SviluppoFacciateBuilder {
    private struct VerticeOBJ: Hashable {
        let posizione: Int
        let texture: Int
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
    }

    static func costruisci(
        objURL: URL,
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

            var verticale = up - normale * simd_dot(up, normale)
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
                invertiU: false))
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
                // La faccia viene ribaltata per portare lo spigolo condiviso
                // sul lato corretto: anche U deve seguire lo stesso ribaltamento.
                piani[indice].uv = corrente.uv.map { SIMD2(1 - $0.x, $0.y) }
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

        for piano in piani {
            let larghezzaPiano = max(piano.maxX - piano.minX, 0)
            let altezzaPiano = max(piano.maxY - piano.minY, 0)
            pianiSviluppati.append(PianoSviluppato(
                indice: piano.indice,
                origineX: cursoreX,
                origineY: piano.minY - minYGlobale,
                larghezza: larghezzaPiano,
                altezza: altezzaPiano,
                invertiU: piano.invertiU))
            let sviluppati = piano.punti.map { punto -> SCNVector3 in
                let x = cursoreX + simd_dot(punto, piano.orizzontale) - piano.minX
                let y = simd_dot(punto, piano.verticale) - minYGlobale
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
                                         piani: pianiSviluppati)
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
            material.diffuse.contents = color.withAlphaComponent(0.42)
            material.emission.contents = color.withAlphaComponent(0.22)
            material.lightingModel = .constant
            material.isDoubleSided = true
            shape.materials = [material]
            let nodo = SCNNode(geometry: shape)
            nodo.name = "apertura-\(apertura.id)"
            nodo.position.z = 0.02
            contenitore.addChildNode(nodo)
        }
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
    let onAperturaTap: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = UIColor(red: 0.075, green: 0.082, blue: 0.09, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        context.coordinator.onAperturaTap = onAperturaTap
        context.coordinator.installa(in: view, documento: documento)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== documento.scena {
            context.coordinator.installa(in: view, documento: documento)
        } else {
            context.coordinator.documento = documento
        }
        context.coordinator.onAperturaTap = onAperturaTap
        DispatchQueue.main.async { context.coordinator.inquadra() }
    }

    final class Coordinator: NSObject {
        weak var view: SCNView?
        var documento: SviluppoFacciateDocumento?
        var onAperturaTap: ((String) -> Void)?
        private var ultimaDimensione: CGSize = .zero

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
            DispatchQueue.main.async { self.inquadra(forzato: true) }
        }

        func inquadra(forzato: Bool = false) {
            guard let view, let documento, view.bounds.width > 0, view.bounds.height > 0,
                  let camera = view.pointOfView?.camera else { return }
            if !forzato, view.bounds.size == ultimaDimensione { return }
            ultimaDimensione = view.bounds.size
            let rapporto = Float(view.bounds.width / view.bounds.height)
            // `orthographicScale` rappresenta circa la semialtezza visibile:
            // il fattore 0,58 lascia un margine del 16% attorno allo sviluppo.
            let scala = max(documento.altezza * 0.58,
                            documento.larghezza / max(rapporto, 0.01) * 0.58)
            camera.orthographicScale = Double(max(scala, 0.1))
            view.pointOfView?.position = SCNVector3(0, 0, 100)
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
            inquadra(forzato: true)
        }
    }
}
