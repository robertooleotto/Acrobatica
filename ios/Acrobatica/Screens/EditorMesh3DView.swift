import SwiftUI
import SceneKit
import simd
import Foundation

/// Editor 3D della mesh di facciata (Object Capture).
///
/// FASE 1 (fondamenta): visore SceneKit con orbit/pan/zoom e auto-inquadratura
/// sul bounding box. Carica una mesh OBJ/USDZ da file locale, oppure una mesh
/// demo procedurale (muro + balcone sporgente + triangoli sparsi) per provare
/// al simulatore senza la mesh vera.
///
/// FASI SUCCESSIVE (vedi HANDOFF_editor_3d_ios.md): selezione regioni → taglio
/// distruttivo dei triangoli → denoise → estrazione piani per la proiezione.
struct EditorMesh3DView: View {
    @StateObject private var model: Mesh3DModel
    private let onChiudi: (() -> Void)?
    private let onRipartiDaRaw: (() -> Void)?
    private let sessionId: String?
    private let consentiAutoPianiAllApertura: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var urlsExport: [URL] = []
    @State private var caricandoCloud = false
    @State private var toastCloud: String?
    @State private var autoRiconoscimentoFatto = false
    @State private var autoSalvataggioTask: Task<Void, Never>?
    @State private var autoSalvataggioInCorso = false
    @State private var revisioneMeshSalvata = 0
    @State private var revisioneWorkspaceSalvata = 0
    @State private var meshKindRiconoscimento: String
    @State private var confermaRipartenza = false
    /// Strumenti del vecchio flusso di costruzione/rifinitura manuale. Restano
    /// implementati, ma non occupano il pannello del flusso automatico corrente.
    private let abilitaControlliManualiPiani = false

    private var cloudOccupato: Bool {
        caricandoCloud || autoSalvataggioInCorso
    }

    private var workspaceSalvato: Bool {
        model.meshRevision <= revisioneMeshSalvata
            && model.workspaceRevision <= revisioneWorkspaceSalvata
    }

    /// `meshFile` nil → mesh demo procedurale. `sessionId` presente → abilita il
    /// salvataggio della mesh RIPULITA sul backend (kind=clean).
    init(meshFile: URL? = nil,
         textureFile: URL? = nil,
         nome: String = "Mesh facciata",
         sessionId: String? = nil,
         meshKind: String = "raw",
         consentiAutoPianiAllApertura: Bool = false,
         onRipartiDaRaw: (() -> Void)? = nil,
         onChiudi: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: Mesh3DModel(
            meshFile: meshFile, textureFile: textureFile, nome: nome))
        _meshKindRiconoscimento = State(initialValue: meshKind)
        self.sessionId = sessionId
        self.consentiAutoPianiAllApertura = consentiAutoPianiAllApertura
        self.onRipartiDaRaw = onRipartiDaRaw
        self.onChiudi = onChiudi
    }

    /// Esporta la mesh ripulita e la carica sul backend come `clean`.
    private func salvaSuCloud() {
        guard let sid = sessionId, !cloudOccupato else { return }
        autoSalvataggioTask?.cancel()
        let nome = model.nome.replacingOccurrences(of: " ", with: "_")
        guard let obj = model.esportaMeshRipulita(nomeBase: nome).first else {
            toastCloud = "Nessuna mesh da salvare"; return
        }
        guard let piani = model.esportaPianiPayload(includiVuoto: true) else {
            toastCloud = "Impossibile preparare i piani"; return
        }
        let revisioneMesh = model.meshRevision
        let revisioneWorkspace = model.workspaceRevision
        caricandoCloud = true
        toastCloud = "Sincronizzo mesh e piani…"
        Task {
            do {
                _ = try await BackendAPIClient.shared.uploadMesh(sessionId: sid, fileURL: obj, kind: "clean")
                _ = try await BackendAPIClient.shared.uploadPlanes(
                    sessionId: sid, jsonData: piani)
                revisioneMeshSalvata = max(revisioneMeshSalvata, revisioneMesh)
                revisioneWorkspaceSalvata = max(
                    revisioneWorkspaceSalvata, revisioneWorkspace)
                toastCloud = "Mesh e piani sincronizzati ✓"
            } catch {
                toastCloud = "Upload fallito: \(error.localizedDescription)"
            }
            caricandoCloud = false
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toastCloud?.contains("✓") == true { toastCloud = nil }
        }
    }

    /// Serializza i piani decisi e li carica sul backend (out/planes.json su
    /// storage) come input della proiezione foto→piani (passo 7).
    private func salvaPianiSuCloud() {
        guard let sid = sessionId, !cloudOccupato else { return }
        autoSalvataggioTask?.cancel()
        guard let data = model.esportaPianiPayload() else {
            toastCloud = "Nessun piano da salvare"; return
        }
        caricandoCloud = true
        toastCloud = "Carico i piani…"
        Task {
            do {
                let r = try await BackendAPIClient.shared.uploadPlanes(sessionId: sid, jsonData: data)
                revisioneWorkspaceSalvata = max(
                    revisioneWorkspaceSalvata, model.workspaceRevision)
                toastCloud = "Piani salvati sul cloud (\(r.count)) ✓"
            } catch {
                toastCloud = "Upload piani fallito: \(error.localizedDescription)"
            }
            caricandoCloud = false
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toastCloud?.contains("✓") == true { toastCloud = nil }
        }
    }

    private func proiettaTextureSuPiani() {
        guard let sid = sessionId, !cloudOccupato else { return }
        autoSalvataggioTask?.cancel()
        let nome = model.nome.replacingOccurrences(of: " ", with: "_")
        guard let obj = model.esportaMeshRipulita(nomeBase: nome).first,
              let planes = model.esportaPianiPayload() else {
            toastCloud = "Servono mesh e piani validi"; return
        }
        let revisioneMesh = model.meshRevision
        let revisioneWorkspace = model.workspaceRevision
        caricandoCloud = true
        toastCloud = "Carico la mesh pulita…"
        Task {
            do {
                _ = try await BackendAPIClient.shared.uploadMesh(
                    sessionId: sid, fileURL: obj, kind: "clean")
                toastCloud = "Carico i piani revisionati…"
                _ = try await BackendAPIClient.shared.uploadPlanes(
                    sessionId: sid, jsonData: planes)
                revisioneMeshSalvata = max(revisioneMeshSalvata, revisioneMesh)
                revisioneWorkspaceSalvata = max(
                    revisioneWorkspaceSalvata, revisioneWorkspace)
                toastCloud = "Avvio la proiezione…"
                var result = try await BackendAPIClient.shared.projectPlanes(sessionId: sid)
                var polls = 0
                var erroriPollingConsecutivi = 0
                while result.state == "queued" || result.state == "running" {
                    let percent = Int((result.progress * 100).rounded())
                    toastCloud = "\(result.message) · \(percent)%"
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    do {
                        result = try await BackendAPIClient.shared.projectionStatus(sessionId: sid)
                        erroriPollingConsecutivi = 0
                    } catch let urlError as URLError {
                        switch urlError.code {
                        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                             .notConnectedToInternet, .cannotFindHost:
                            erroriPollingConsecutivi += 1
                            if erroriPollingConsecutivi >= 12 { throw urlError }
                            toastCloud = "Server occupato, continuo ad attendere…"
                            continue
                        default:
                            throw urlError
                        }
                    }
                    polls += 1
                    if polls >= 360 {
                        throw NSError(
                            domain: "AcrobaticaProjection", code: 3,
                            userInfo: [NSLocalizedDescriptionKey:
                                "La proiezione non si è conclusa entro 30 minuti"])
                    }
                }
                if result.state == "failed" {
                    throw NSError(
                        domain: "AcrobaticaProjection", code: 4,
                        userInfo: [NSLocalizedDescriptionKey:
                            result.error.isEmpty ? "Errore nel calcolo cloud" : result.error])
                }
                let bundle = try await BackendAPIClient.shared.downloadProjectionBundle(
                    sessionId: sid, files: result.files)
                guard let main = result.main_obj, let url = bundle[main.name] else {
                    throw NSError(
                        domain: "AcrobaticaProjection", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "OBJ texturizzato non ricevuto"])
                }
                try model.caricaPianiTexturizzati(url)
                toastCloud = String(
                    format: "Texture pronta: %d piani, copertura %.0f%% ✓",
                    result.count, result.coverage * 100)
            } catch {
                toastCloud = "Proiezione fallita: \(error.localizedDescription)"
            }
            caricandoCloud = false
        }
    }

    private func caricaUltimaTexture() {
        guard let sid = sessionId, !cloudOccupato else { return }
        caricandoCloud = true
        toastCloud = "Scarico i piani texturizzati…"
        Task {
            do {
                let result = try await BackendAPIClient.shared.projectionStatus(sessionId: sid)
                guard result.state == "complete", let main = result.main_obj else {
                    throw NSError(
                        domain: "AcrobaticaProjection", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Nessuna texture completata"])
                }
                let bundle = try await BackendAPIClient.shared.downloadProjectionBundle(
                    sessionId: sid, files: result.files)
                guard let url = bundle[main.name] else {
                    throw NSError(
                        domain: "AcrobaticaProjection", code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "OBJ texturizzato non ricevuto"])
                }
                try model.caricaPianiTexturizzati(url)
                await ripristinaPianiSalvati(sessionId: sid)
                toastCloud = "Texture calcolata caricata ✓"
            } catch {
                toastCloud = "Download fallito: \(error.localizedDescription)"
            }
            caricandoCloud = false
        }
    }

    /// All'apertura mostra subito il risultato automatico se il backend lo ha
    /// gia prodotto; in assenza di un bake conserva il riconoscimento editoriale.
    private func preparaRisultatoAutomatico(sessionId sid: String) async {
        do {
            let result = try await BackendAPIClient.shared.projectionStatus(sessionId: sid)
            guard result.state == "complete", let main = result.main_obj else {
                if result.state == "queued" || result.state == "running" {
                    toastCloud = result.message
                } else if consentiAutoPianiAllApertura {
                    await model.riconosciPianiAuto(
                        sessionId: sid, meshKind: meshKindRiconoscimento)
                } else {
                    toastCloud = "Mesh OC originale: puoi riconoscere i piani o pulirla"
                }
                return
            }
            caricandoCloud = true
            toastCloud = "Scarico il risultato texturizzato…"
            defer { caricandoCloud = false }
            let bundle = try await BackendAPIClient.shared.downloadProjectionBundle(
                sessionId: sid, files: result.files)
            guard let url = bundle[main.name] else {
                throw NSError(
                    domain: "AcrobaticaProjection", code: 7,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Il bundle automatico non contiene l'OBJ principale"])
            }
            try model.caricaPianiTexturizzati(url)
            await ripristinaPianiSalvati(sessionId: sid)
            toastCloud = "Modello texturizzato pronto ✓"
        } catch {
            toastCloud = "Risultato automatico non disponibile"
            if consentiAutoPianiAllApertura {
                await model.riconosciPianiAuto(
                    sessionId: sid, meshKind: meshKindRiconoscimento)
            }
        }
    }

    @MainActor
    private func ripristinaPianiSalvati(sessionId: String) async {
        guard model.facce.isEmpty else { return }
        do {
            let planes = try await BackendAPIClient.shared.downloadSavedPlanes(
                sessionId: sessionId)
            guard !planes.isEmpty else { return }
            model.applicaPianiRilevati(planes, registraModifica: false)
        } catch {
            await model.riconosciPianiAuto(
                sessionId: sessionId, meshKind: meshKindRiconoscimento)
        }
    }

    private func pianificaSalvataggioAutomatico() {
        guard sessionId != nil else { return }
        guard !autoSalvataggioInCorso else { return }
        autoSalvataggioTask?.cancel()
        autoSalvataggioTask = Task {
            do {
                try await Task.sleep(nanoseconds: 1_200_000_000)
                try Task.checkCancellation()
                await eseguiSalvataggioAutomatico()
            } catch {
                // Una nuova modifica sostituisce il debounce precedente.
            }
        }
    }

    @MainActor
    private func eseguiSalvataggioAutomatico() async {
        guard let sid = sessionId else { return }
        if caricandoCloud {
            pianificaSalvataggioAutomatico()
            return
        }

        let revisioneWorkspace = model.workspaceRevision
        let revisioneMesh = model.meshRevision
        let deveCaricareMesh = revisioneMesh > revisioneMeshSalvata
        let deveCaricarePiani = revisioneWorkspace > revisioneWorkspaceSalvata
        guard deveCaricareMesh || deveCaricarePiani else { return }

        let nome = model.nome.replacingOccurrences(of: " ", with: "_")
        let obj = deveCaricareMesh
            ? model.esportaMeshRipulita(nomeBase: nome).first
            : nil
        guard !deveCaricareMesh || obj != nil else {
            toastCloud = "Autosave mesh fallito: esportazione non riuscita"
            return
        }
        // Una nuova geometria invalida i piani precedenti. Il detector viene
        // rilanciato sulla revisione clean appena caricata; i nuovi piani saranno
        // salvati dal debounce successivo della workspaceRevision.
        let piani = deveCaricareMesh
            ? nil
            : model.esportaPianiPayload(includiVuoto: true)

        autoSalvataggioInCorso = true
        defer {
            autoSalvataggioInCorso = false
            if model.workspaceRevision > revisioneWorkspaceSalvata
                || model.meshRevision > revisioneMeshSalvata {
                pianificaSalvataggioAutomatico()
            }
        }
        do {
            if let obj {
                _ = try await BackendAPIClient.shared.uploadMesh(
                    sessionId: sid, fileURL: obj, kind: "clean")
                revisioneMeshSalvata = max(revisioneMeshSalvata, revisioneMesh)
                meshKindRiconoscimento = "clean"
                await model.riconosciPianiAuto(sessionId: sid, meshKind: "clean")
            }
            if let piani {
                _ = try await BackendAPIClient.shared.uploadPlanes(
                    sessionId: sid, jsonData: piani)
            }
            revisioneWorkspaceSalvata = max(
                revisioneWorkspaceSalvata, revisioneWorkspace)
        } catch {
            toastCloud = "Autosave non riuscito: \(error.localizedDescription)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            barraSuperiore
            ZStack(alignment: .topTrailing) {
                SceneKitContainer(model: model)
                if model.modoPerimetro && model.perimetroTraccia { PannelloPerimetro(model: model) }
                hud
                NavGizmo(model: model).padding(.top, 8).padding(.trailing, 78)
                railDestro
            }
            barraStrumenti
        }
        .background(EditorTheme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let t = toastCloud {
                HStack(spacing: 8) {
                    if cloudOccupato { ProgressView().tint(.white).scaleEffect(0.8) }
                    Text(t).font(Theme.Typo.caption(12)).foregroundStyle(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.black.opacity(0.82), in: Capsule())
                .padding(.bottom, 92)
                .onTapGesture { toastCloud = nil }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: toastCloud)
        .confirmationDialog(
            "Ripartire dalla mesh OC originale?",
            isPresented: $confermaRipartenza,
            titleVisibility: .visible
        ) {
            Button("Elimina tutte le elaborazioni", role: .destructive) {
                if let onRipartiDaRaw {
                    onRipartiDaRaw()
                } else {
                    model.ricaricaDaCapo()
                }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Verranno rimossi mesh pulita, piani, texture proiettate e aperture. Foto e mesh OC originale resteranno disponibili.")
        }
        // Ripristina un risultato esistente. Sulla raw il riconoscimento resta
        // manuale, così l'operatore può prima confrontare la mesh OC completa.
        .onChange(of: model.numTriangoli) { n in
            if n > 0, let sid = sessionId, model.facce.isEmpty, !autoRiconoscimentoFatto {
                autoRiconoscimentoFatto = true
                Task { await preparaRisultatoAutomatico(sessionId: sid) }
            }
        }
        .onChange(of: model.workspaceRevision) { _ in
            pianificaSalvataggioAutomatico()
        }
        .sheet(isPresented: Binding(
            get: { !urlsExport.isEmpty },
            set: { if !$0 { urlsExport = [] } }
        )) {
            CondivisioneMesh(elementi: urlsExport)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sheet(isPresented: $model.mostraProfilo) {
            ProfiloRilievoSheet(model: model)
                .presentationDetents([.medium, .large])
        }
    }

    private var barraSuperiore: some View {
        HStack(spacing: 14) {
            Button {
                if let onChiudi { onChiudi() } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EditorTheme.testo)
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.nome)
                    .font(Theme.Typo.title(15))
                    .foregroundStyle(EditorTheme.testo)
                    .lineLimit(1)
                Text("Pulizia mesh")
                    .font(Theme.Typo.caption(10))
                    .foregroundStyle(EditorTheme.testoMuto)
                    .lineLimit(1)
            }
            .fixedSize()
            Spacer()
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 36)
            }
            .disabled(!model.puoUndo)
            .foregroundStyle(model.puoUndo ? EditorTheme.testo : EditorTheme.testoMuto.opacity(0.4))
            Button { model.redo() } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 36)
            }
            .disabled(!model.puoRedo)
            .foregroundStyle(model.puoRedo ? EditorTheme.testo : EditorTheme.testoMuto.opacity(0.4))
            if sessionId != nil {
                Button { salvaSuCloud() } label: {
                    Image(systemName: cloudOccupato
                          ? "arrow.triangle.2.circlepath"
                          : (workspaceSalvato ? "checkmark.icloud" : "icloud.and.arrow.up"))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(model.numTriangoli == 0 ? EditorTheme.testoMuto.opacity(0.4) : EditorTheme.accento)
                }
                .disabled(model.numTriangoli == 0 || cloudOccupato)
            }
            Menu {
                Button {
                    let nome = model.nome.replacingOccurrences(of: " ", with: "_")
                    urlsExport = model.esportaMeshRipulita(nomeBase: nome)
                } label: { Label("Esporta mesh (file)", systemImage: "tray.and.arrow.down") }
                    .disabled(model.numTriangoli == 0)
                Button {
                    let nome = model.nome.replacingOccurrences(of: " ", with: "_")
                    urlsExport = model.esportaProxy(nomeBase: nome)
                } label: { Label("Esporta piani", systemImage: "square.and.arrow.up") }
                    .disabled(model.facce.isEmpty)
                if sessionId != nil {
                    Divider()
                    Button { salvaPianiSuCloud() } label: {
                        Label("Salva piani sul cloud", systemImage: "cloud.and.arrow.up")
                    }
                    .disabled(model.facce.isEmpty || cloudOccupato)
                    Button { proiettaTextureSuPiani() } label: {
                        Label("Proietta texture sui piani", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(model.facce.isEmpty || model.numTriangoli == 0 || cloudOccupato)
                    Button { caricaUltimaTexture() } label: {
                        Label("Carica texture calcolata", systemImage: "arrow.down.square")
                    }
                    .disabled(cloudOccupato)
                    Divider()
                    Button(role: .destructive) {
                        confermaRipartenza = true
                    } label: {
                        Label("Riparti dalla mesh OC", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(cloudOccupato)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 36, height: 36)
                    .foregroundStyle(EditorTheme.testo)
            }
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(EditorTheme.panel)
        .overlay(Rectangle().fill(EditorTheme.hair).frame(height: 1), alignment: .bottom)
    }

    /// Menu delle viste (proxy/piani/geometria/texture/validazione) — nel rail.
    private var vistaMenu: some View {
        Menu {
            Button { model.mostraProxy.toggle() } label: {
                Label("Proxy colorati", systemImage: model.mostraProxy ? "checkmark" : "circle")
            }
            Button { model.mostraPiani.toggle() } label: {
                Label("Piani fittati", systemImage: model.mostraPiani ? "checkmark" : "circle")
            }
            Divider()
            Button { model.mostraMesh.toggle() } label: {
                Label("Geometria OC", systemImage: model.mostraMesh ? "checkmark" : "circle")
            }
            if model.haTexturaOC {
                Button { model.mostraTexturaOC.toggle() } label: {
                    Label("Texture OC", systemImage: model.mostraTexturaOC ? "checkmark" : "circle")
                }
            }
            Divider()
            Button { model.visteOrtografiche.toggle() } label: {
                Label(model.visteOrtografiche ? "Snap ortografici" : "Snap prospettici",
                      systemImage: model.visteOrtografiche ? "viewfinder" : "camera.viewfinder")
            }
            Divider()
            ForEach(VistaValidazione.allCases) { v in
                Button { model.vistaValidazione = v } label: {
                    Label(v.etichetta, systemImage: model.vistaValidazione == v ? "checkmark" : "")
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "eye")
                    .font(.system(size: 16, weight: .medium))
                Text("Vista")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(EditorTheme.testo)
            .frame(width: 60, height: 42)
            .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityLabel("Opzioni vista")
    }

    /// Rail verticale a destra: strumenti di modifica separati dai controlli vista.
    private var railDestro: some View {
        HStack {
            Spacer()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 5) {
                    ForEach(StrumentoMesh3D.allCases.filter { $0 != .punti && $0 != .seleziona }) { s in
                        PulsanteStrumento3D(strumento: s, attivo: model.strumento == s) {
                            model.annullaFaccia(); model.strumento = s
                        }
                        .help(s.etichetta)
                    }
                    railDivisore
                    vistaMenu
                    HStack(spacing: 0) {
                        Button { model.zoomVista(1.25) } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 30, height: 36)
                        }
                        .help("Ingrandisci")
                        Button { model.zoomVista(0.80) } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 30, height: 36)
                        }
                        .help("Riduci")
                    }
                    .foregroundStyle(EditorTheme.testo)
                    .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 7))
                    Button { model.inquadra() } label: {
                        Label("Inquadra", systemImage: "scope")
                            .font(.system(size: 9, weight: .semibold))
                            .labelStyle(.iconOnly)
                            .foregroundStyle(EditorTheme.testo)
                            .frame(width: 60, height: 36)
                            .background(EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .help("Inquadra tutto")
                    railDivisore
                    Button {
                        if onRipartiDaRaw != nil {
                            confermaRipartenza = true
                        } else {
                            model.ricaricaDaCapo()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.danger)
                            .frame(width: 60, height: 36)
                    }
                    .disabled(model.caricamento || model.numTriangoli == 0)
                    .help("Ripristina mesh")
                }
                .padding(5)
                .background(EditorTheme.panel.opacity(0.94),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(EditorTheme.hair, lineWidth: 1))
                Spacer()
            }
            .padding(.trailing, 8)
        }
    }

    private var railDivisore: some View {
        Rectangle().fill(EditorTheme.hair).frame(width: 22, height: 1).padding(.vertical, 2)
    }

    private var hud: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 8) {
                if let err = model.errore {
                    Text(err)
                        .font(Theme.Typo.caption(11))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(EditorTheme.panel.opacity(0.9),
                                    in: RoundedRectangle(cornerRadius: 6))
                } else if let info = model.cursoreInfo {
                    Label(info, systemImage: "scope")
                        .font(Theme.Typo.mono(10))
                        .foregroundStyle(EditorTheme.accento)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(EditorTheme.panel.opacity(0.9),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                if model.caricamento {
                    ProgressView().tint(EditorTheme.accento)
                        .padding(10)
                        .background(EditorTheme.panel.opacity(0.9), in: Circle())
                }
            }
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    // MARK: – Barra strumenti (Fase 2: creazione faccia per punti)

    /// Barra inferiore = SOLO contesto dello strumento attivo (gli strumenti sono
    /// nel rail a destra). In Naviga non c'è barra: massimo spazio al modello.
    @ViewBuilder private var barraStrumenti: some View {
        if model.modoPerimetro {
            barraPerimetro
                .padding(.vertical, 8)
                .background(EditorTheme.panel)
                .overlay(Rectangle().fill(EditorTheme.hair).frame(height: 1), alignment: .top)
        } else if model.strumento != .orbita {
            VStack(spacing: 8) {
                if model.strumento == .box { barraBox }
                if model.strumento == .facce { barraPiani }
                if model.strumento == .assi { barraAssiManuali }
                if model.strumento == .allinea { barraAllinea }
            }
            .padding(.vertical, 8)
            .background(EditorTheme.panel)
            .overlay(Rectangle().fill(EditorTheme.hair).frame(height: 1), alignment: .top)
        }
    }

    private var barraAllinea: some View {
        VStack(spacing: 8) {
            // riga A — selezione: selettori scorrevoli, conteggio/azioni fissi a destra
            HStack(spacing: 6) {
              ScrollView(.horizontal, showsIndicators: false) {
               HStack(spacing: 6) {
                ForEach([ModoSelezione.tocco, .rettangolo, .lazo]) { m in
                    Button { model.modoSelezione = m } label: {
                        Label(m == .tocco ? "Puntatore" : m.etichetta, systemImage: m == .tocco ? "hand.point.up.left" : m.icona)
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.modoSelezione == m ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.modoSelezione == m ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Divider().frame(height: 18)
                ForEach(ElementoTipo.allCases) { t in
                    Button { model.tipoElemento = t; model.deselezionaAllinea() } label: {
                        Label(t.etichetta, systemImage: t.icona)
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.tipoElemento == t ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.tipoElemento == t ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
               }
              }
                Text("\(model.numElementiSel) sel").font(Theme.Typo.mono(10)).foregroundStyle(EditorTheme.testoMuto)
                Button { model.deselezionaAllinea() } label: {
                    Image(systemName: "xmark.circle").foregroundStyle(EditorTheme.testoMuto)
                }
            }
            // riga B — assi scorrevoli, azioni (Sposta/Allinea) fisse a destra
            HStack(spacing: 6) {
              ScrollView(.horizontal, showsIndicators: false) {
               HStack(spacing: 6) {
                Picker("", selection: $model.rifAssiAllinea) {
                    ForEach(AssiRiferimento.allCases) { Text($0.etichetta).tag($0) }
                }.pickerStyle(.segmented).frame(width: 150)
                let nomi = model.rifAssiAllinea == .mondo ? ["X", "Y", "Z"] : ["Oriz", "Vert", "Prof"]
                assiToggle(nomi[0], isOn: $model.allineaAsse0)
                assiToggle(nomi[1], isOn: $model.allineaAsse1)
                assiToggle(nomi[2], isOn: $model.allineaAsse2)
               }
              }
                Button { model.spostaAllinea.toggle() } label: {
                    Label("Sposta", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(Theme.Typo.caption(11, .semibold))
                        .foregroundStyle(model.spostaAllinea ? .white : EditorTheme.testo)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(model.spostaAllinea ? EditorTheme.accento : EditorTheme.panelAlt,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(model.numElementiSel == 0).opacity(model.numElementiSel == 0 ? 0.5 : 1)
                Button { model.attendoSorgenteAllinea.toggle() } label: {
                    Label(model.attendoSorgenteAllinea ? "Tocca il sorgente…" : "Allinea",
                          systemImage: "scope")
                        .font(Theme.Typo.caption(12, .bold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(model.attendoSorgenteAllinea ? Color.orange
                                    : Color(red: 0.18, green: 0.70, blue: 0.44), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
                .disabled(model.numElementiSel == 0).opacity(model.numElementiSel == 0 ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 12)
    }

    private func assiToggle(_ nome: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(nome).font(Theme.Typo.caption(11, .bold))
                .foregroundStyle(isOn.wrappedValue ? .white : EditorTheme.testo)
                .frame(width: 46).padding(.vertical, 6)
                .background(isOn.wrappedValue ? EditorTheme.accento : EditorTheme.panelAlt,
                            in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var barraAssiManuali: some View {
        HStack(spacing: 8) {
            Label(model.testoPassoAssiManuali, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(Theme.Typo.caption(11))
                .foregroundStyle(EditorTheme.testoMuto)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            ChipSelezione("Reset", "arrow.counterclockwise") { model.resetAssiManuali() }.fixedSize()
            ChipSelezione("Auto", "wand.and.stars") { model.ricalcolaAssiAutomatici() }.fixedSize()
            ChipSelezione("Flip", "arrow.left.arrow.right") { model.flipAssiFronte() }.fixedSize()
            Button { model.snapFronte() } label: {
                Label("Fronte", systemImage: "viewfinder")
                    .font(Theme.Typo.caption(12, .bold))
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(EditorTheme.accento, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
    }

    private var barraPerimetro: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scissors").font(.system(size: 13))
                    .foregroundStyle(EditorTheme.accento)
                Text(model.perimetroTraccia ? "Quota" : "Posiziona la sezione")
                    .font(Theme.Typo.caption(11)).foregroundStyle(EditorTheme.testoMuto)
                Slider(value: $model.quotaSlice, in: 0...1).tint(EditorTheme.accento)
                Text("\(Int(model.quotaSlice * 100))%").font(Theme.Typo.mono(10))
                    .foregroundStyle(EditorTheme.testoMuto).frame(width: 36, alignment: .trailing)
            }
            if !model.perimetroTraccia {
                // FASE 1: posiziona la sezione sul 3D, poi passa a tracciare
                HStack(spacing: 8) {
                    Text("sposta lo slice; ruota la vista se vuoi")
                        .font(Theme.Typo.caption(10)).foregroundStyle(EditorTheme.testoMuto)
                    Spacer()
                    Button { model.iniziaTraccia() } label: {
                        Label("Traccia il bordo", systemImage: "scribble.variable")
                            .font(Theme.Typo.caption(12, .bold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(EditorTheme.accento, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    Button { model.esciPerimetro() } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(EditorTheme.testoMuto)
                    }
                }
            } else {
                // FASE 2: tracciamento nel pannello 2D
                // riga A — regole angoli: sensibilità + snap on/off
                HStack(spacing: 8) {
                    Image(systemName: "angle").font(.system(size: 12)).foregroundStyle(EditorTheme.testoMuto)
                    Text("Angoli").font(Theme.Typo.caption(10)).foregroundStyle(EditorTheme.testoMuto)
                    Slider(value: $model.sensibilitaAngoli, in: 0...1).tint(EditorTheme.accento)
                        .frame(maxWidth: 160)
                    Text("pochi").font(Theme.Typo.caption(9)).foregroundStyle(EditorTheme.testoMuto)
                    Button { model.snapPerimetroAttivo.toggle() } label: {
                        Label("Snap", systemImage: model.snapPerimetroAttivo ? "scope" : "scope")
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.snapPerimetroAttivo ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.snapPerimetroAttivo ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                }
                // riga B — azioni: chiudi, auto, anelli, estrudi
                HStack(spacing: 8) {
                    Button { model.perimetroTraccia = false } label: {
                        Label("Sposta", systemImage: "arrow.up.and.down")
                            .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { model.chiudiPerimetro.toggle() } label: {
                        Label("Chiudi", systemImage: model.chiudiPerimetro ? "checkmark.circle.fill" : "circle")
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.chiudiPerimetro ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.chiudiPerimetro ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { model.autoPerimetro() } label: {
                        Label("Auto", systemImage: "wand.and.stars")
                            .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                    }
                    // anelli a più quote → piani inclinati
                    Button { model.salvaAnelloPerimetro() } label: {
                        Label("Salva anello", systemImage: "square.stack.3d.down.right")
                            .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(model.numPuntiPerimetro < 2).opacity(model.numPuntiPerimetro < 2 ? 0.4 : 1)
                    if model.numAnelliPerimetro > 0 {
                        Button { model.copiaUltimoAnelloAllaQuota() } label: {
                            Label("Copia qui", systemImage: "doc.on.doc")
                                .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text("anelli: \(model.numAnelliPerimetro)").font(Theme.Typo.mono(10))
                            .foregroundStyle(EditorTheme.accento)
                    }
                    Spacer()
                    Button { model.annullaUltimoPuntoPerimetro() } label: {
                        Label("Indietro", systemImage: "arrow.uturn.backward")
                            .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                    }
                    .disabled(model.numPuntiPerimetro == 0).opacity(model.numPuntiPerimetro == 0 ? 0.4 : 1)
                    Button { model.estrudiPerimetroInclinato() } label: {
                        Label(model.numAnelliPerimetro > 0 ? "Estrudi inclinato" : "Estrudi (\(model.numPuntiPerimetro))",
                              systemImage: "square.stack.3d.up.fill")
                            .font(Theme.Typo.caption(12, .bold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(red: 0.18, green: 0.70, blue: 0.44), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    .disabled(model.numPuntiPerimetro < 2 && model.numAnelliPerimetro < 2)
                    .opacity((model.numPuntiPerimetro < 2 && model.numAnelliPerimetro < 2) ? 0.5 : 1)
                    Button { model.esciPerimetro() } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(EditorTheme.testoMuto)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var barraPiani: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { model.attivaPuntoZero() } label: {
                    Label(model.attendePuntoZero ? "Punti attivi" : "Punti aderenza",
                          systemImage: "scope")
                        .font(Theme.Typo.caption(12, .semibold))
                        .foregroundStyle(model.attendePuntoZero ? .white : EditorTheme.testo)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(model.attendePuntoZero ? EditorTheme.accento : EditorTheme.panelAlt,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(model.facce.isEmpty)
                .opacity(model.facce.isEmpty ? 0.45 : 1)

                if !model.attendePuntoZero {
                    Button { model.allineaPianiInAltezza() } label: {
                        Label("Allinea in altezza", systemImage: "arrow.up.and.down")
                            .font(Theme.Typo.caption(12, .semibold))
                            .foregroundStyle(EditorTheme.testo)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(!model.puoAllinearePianiInAltezza)
                    .opacity(model.puoAllinearePianiInAltezza ? 1 : 0.45)
                }

                Spacer(minLength: 0)

                if model.attendePuntoZero {
                    Text("\(model.numPuntiRevisione)")
                        .font(Theme.Typo.mono(11))
                        .foregroundStyle(EditorTheme.accento)
                        .frame(minWidth: 24, minHeight: 28)
                        .background(EditorTheme.panelAlt,
                                    in: RoundedRectangle(cornerRadius: 7))
                    Button { model.applicaRevisionePiani() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.numPuntiRevisione > 0
                                     ? EditorTheme.accento : EditorTheme.testoMuto)
                    .disabled(model.numPuntiRevisione == 0)
                    .help("Applica punti")

                    Button { model.annullaRevisionePiani() } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(EditorTheme.testoMuto)
                    .help("Annulla punti")
                }
            }
        }
        .padding(.horizontal, 12)
    }

    /// Vecchi controlli mantenuti nel modello ma rimossi dal flusso operativo.
    private var barraPianiAvanzata: some View {
        VStack(spacing: 8) {
            // 1 · MODO — scorrevole in orizzontale: troppi bottoni per la larghezza iPhone.
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 6) {
                ForEach(ModoSelezione.allCases.filter { $0 != .poligonale }) { m in
                    Button { model.modoSelezione = m } label: {
                        Label(m.etichetta, systemImage: m.icona)
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.modoSelezione == m ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.modoSelezione == m ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Divider().frame(height: 20).padding(.horizontal, 2)
                if model.modoSelezione.selezioneMesh {
                    Button { model.selezioneAdditiva.toggle() } label: {
                        Label("Aggiungi", systemImage: model.selezioneAdditiva ? "plus.square.fill.on.square.fill" : "plus.square.on.square")
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.selezioneAdditiva ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.selezioneAdditiva ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if model.modoSelezione == .seleziona {
                    Button { model.multiSelezione.toggle() } label: {
                        Label("Multi", systemImage: model.multiSelezione ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(model.multiSelezione ? .white : EditorTheme.testo)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.multiSelezione ? EditorTheme.accento : EditorTheme.panelAlt,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Menu {
                    ForEach(AsseMovimentoPoligono.allCases) { a in
                        Button(a.etichetta) { model.asseMovimentoPoligono = a }
                    }
                } label: {
                    Label(model.asseMovimentoPoligono.etichetta, systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(Theme.Typo.caption(11, .semibold))
                        .foregroundStyle(model.asseMovimentoPoligono == .libero ? EditorTheme.testo : .white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(model.asseMovimentoPoligono == .libero ? EditorTheme.panelAlt : EditorTheme.accento,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                Button { model.mostraProfilo = true } label: {
                    Label("Profilo", systemImage: "slider.horizontal.3")
                        .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                }
                Menu {
                    ForEach(AutoBCSPreset.allCases) { preset in
                        Button(preset.etichetta) { model.applicaPresetAutoBCS(preset) }
                    }
                } label: {
                    Label(model.autoBCSPreset.etichetta, systemImage: "dial.medium")
                        .font(Theme.Typo.caption(11, .semibold))
                        .foregroundStyle(model.autoBCSPreset == .standard ? EditorTheme.testo : .white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(model.autoBCSPreset == .standard ? EditorTheme.panelAlt : EditorTheme.accento,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                Button { Task { await model.segmentaTuttoAutomatico() } } label: {
                    Label(model.segmentando ? "Rilevo…" : "Auto piani", systemImage: "wand.and.stars")
                        .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(red: 0.18, green: 0.70, blue: 0.44), in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(model.numTriangoli == 0 || model.segmentando)
                Button {
                    if let sid = sessionId {
                        Task {
                            await model.riconosciPianiAuto(
                                sessionId: sid, meshKind: meshKindRiconoscimento)
                        }
                    } else {
                        Task { await model.segmentaPianiBCS() }   // fallback on-device (mesh demo)
                    }
                } label: {
                    Label("Riconosci piani", systemImage: "square.grid.3x3")
                        .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(model.numTriangoli == 0 || model.segmentando)
                Button { model.avviaPerimetro() } label: {
                    Label("Perimetro", systemImage: "scissors")
                        .font(Theme.Typo.caption(11, .semibold)).foregroundStyle(EditorTheme.testo)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(model.numTriangoli == 0)
              }
              .padding(.horizontal, 12)
            }
            if model.modoSelezione == .pennello { controlliPennello }
            if model.modoSelezione == .poligonale {
                HStack(spacing: 8) {
                    Text(model.numPuntiLazoPoligonale == 0 ? "tocca i vertici del contorno" : "\(model.numPuntiLazoPoligonale) punti")
                        .font(Theme.Typo.caption(10))
                        .foregroundStyle(EditorTheme.testoMuto)
                    Spacer()
                    ChipSelezione("Chiudi", "checkmark.circle") { model.chiudiLazoPoligonale() }
                        .disabled(model.numPuntiLazoPoligonale < 3)
                        .opacity(model.numPuntiLazoPoligonale < 3 ? 0.45 : 1)
                    ChipSelezione("Annulla", "xmark.circle") { model.resetLazoPoligonale() }
                }
            }

            // 2 · GENERA — appare solo quando hai marcato qualcosa (semi o selezione)
            if model.numSemi > 0 || model.numSelezionati > 0 {
                HStack(spacing: 8) {
                    Button { model.generaDaMarcatura() } label: {
                        Label(model.numSemi > 0 ? "Genera piani (\(model.numSemi))" : "Trova piano",
                              systemImage: model.numSemi > 0 ? "square.stack.3d.up.fill" : "scope")
                            .font(Theme.Typo.caption(12, .bold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color(red: 0.18, green: 0.70, blue: 0.44), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    if model.facciaAttivaId != nil && model.numSelezionati > 0 {
                        ChipSelezione("Aggiungi a piano", "plus.rectangle.on.rectangle") {
                            model.aggiungiSelezioneAlPianoAttivo()
                        }
                        ChipSelezione("Dentro layer", "square.3.layers.3d.down.right") {
                            model.aggiungiSelezioneAlLayerAttivo()
                        }
                    }
                    Button { model.annullaMarcatura() } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(EditorTheme.testoMuto)
                    }
                    Spacer()
                    if model.numSelezionati > 0 {
                        Text("\(model.numSelezionati) tri").font(Theme.Typo.mono(10))
                            .foregroundStyle(EditorTheme.testoMuto)
                    }
                }
                if model.modoSelezione.selezioneMesh {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ChipSelezione("Tutto", "checklist") { model.selezionaTutto() }
                            ChipSelezione("Niente", "xmark.circle") { model.deselezionaTutto() }
                            ChipSelezione("Inverti", "arrow.2.squarepath") { model.invertiSelezione() }
                            ChipSelezione("Frammenti", "sparkles") { model.selezionaFrammenti() }
                            ChipSelezione("Espandi", "plus.magnifyingglass") { model.espandiSelezione() }
                            ChipSelezione("Restringi", "minus.magnifyingglass") { model.restringiSelezione() }
                            ChipSelezione("Elimina mesh", "trash") { model.eliminaSelezione() }
                        }
                    }
                }
            } else {
                Text(suggerimentoPiani)
                    .font(Theme.Typo.caption(10)).foregroundStyle(EditorTheme.testoMuto)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 3 · PIANO ATTIVO — modifica del piano selezionato
            if let fa = model.facciaAttiva {
                HStack(spacing: 8) {
                    Circle().fill(Color(uiColor: fa.colore)).frame(width: 12, height: 12)
                    TextField("Nome faccia", text: Binding(
                        get: { model.facciaAttiva?.nome ?? "" },
                        set: { if let id = model.facciaAttivaId { model.rinominaFaccia(id, $0) } }))
                        .font(Theme.Typo.body(13, .semibold))
                        .foregroundStyle(EditorTheme.testo)
                        .textFieldStyle(.plain)
                    Menu {
                        ForEach(TipoFaccia.allCases) { t in
                            Button(t.etichetta) { model.cambiaTipoFaccia(fa.id, t) }
                        }
                    } label: {
                        Text(fa.tipo.etichetta)
                            .font(Theme.Typo.caption(11, .semibold))
                            .foregroundStyle(EditorTheme.accento)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(EditorTheme.accento.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    }
                    // Priorità layer (§5): chi sta davanti nel bake.
                    HStack(spacing: 2) {
                        Image(systemName: "square.3.layers.3d").font(.system(size: 10))
                        Text("\(fa.priorita)").font(Theme.Typo.mono(11)).frame(minWidth: 14)
                        Stepper("", value: Binding(
                            get: { model.facciaAttiva?.priorita ?? 0 },
                            set: { model.cambiaPrioritaFaccia(fa.id, $0) }), in: 0...20)
                            .labelsHidden().scaleEffect(0.7).frame(width: 64)
                    }
                    .foregroundStyle(EditorTheme.testoMuto)
                    if let e = fa.erroreRms {
                        Text(String(format: "±%.3f", e))
                            .font(Theme.Typo.mono(10))
                            .foregroundStyle(e < model.sogliaErrore ? EditorTheme.testoMuto : Theme.danger)
                    }
                    if let a = model.areaPoligono(fa) {
                        Text(String(format: "%.2f u²", a))
                            .font(Theme.Typo.mono(10))
                            .foregroundStyle(EditorTheme.accento)
                    }
                    if model.facce.count > 1 {
                        Menu {
                            ForEach(model.facce.filter { $0.id != fa.id }) { altra in
                                Button("Unisci \(altra.nome)") {
                                    model.unisciFacce(target: fa.id, sorgente: altra.id)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.merge")
                                .foregroundStyle(EditorTheme.testo).frame(width: 28, height: 28)
                        }
                    }
                    Button { model.eliminaFaccia(fa.id) } label: {
                        Image(systemName: "trash").foregroundStyle(Theme.danger).frame(width: 28, height: 28)
                    }
                }
                // Riconoscimento dal pennello + revisione multipunto dei piani.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if abilitaControlliManualiPiani {
                            ChipSelezione("Nuovo layer", "plus.square.on.square") {
                                model.nuovaFaccia()
                            }
                            ChipSelezione("Crea facce layer", "square.stack.3d.up.fill") {
                                model.generaPianiDaLayer()
                            }
                            ChipSelezione("Crea spalla", "rectangle.connected.to.line.below") {
                                model.creaSpallaDaPianiSelezionati()
                            }
                            ChipSelezione("Espandi al piano", "arrow.up.backward.and.arrow.down.forward") {
                                model.espandiAlPiano()
                            }
                        }
                        Button { model.attivaPuntoZero() } label: {
                            Label("Rivedi piani", systemImage: "scope")
                                .font(Theme.Typo.caption(11, .semibold))
                                .foregroundStyle(model.attendePuntoZero ? .white : EditorTheme.testo)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(model.attendePuntoZero ? EditorTheme.accento : EditorTheme.panelAlt,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        if model.attendePuntoZero {
                            Text("\(model.numPuntiRevisione) punti")
                                .font(Theme.Typo.caption(10)).foregroundStyle(EditorTheme.accento)
                            Button { model.applicaRevisionePiani() } label: {
                                Image(systemName: "checkmark").frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(model.numPuntiRevisione > 0 ? EditorTheme.accento : EditorTheme.testoMuto)
                            .disabled(model.numPuntiRevisione == 0)
                            .help("Adatta e salda i piani")
                            Button { model.annullaRevisionePiani() } label: {
                                Image(systemName: "xmark").frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(EditorTheme.testoMuto)
                            .help("Annulla revisione")
                        }
                        Spacer()
                    }
                }
                // Rifinitura piano (§6): squadra/verticale/orizzontale/offset.
                if abilitaControlliManualiPiani, fa.pianoNormale != nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ChipSelezione("Squadra", "square.dashed") { model.squadraPiano(fa.id) }
                            ChipSelezione("Verticale", "arrow.up.and.down") { model.pianoVerticale(fa.id) }
                            ChipSelezione("Orizzontale", "arrow.left.and.right") { model.pianoOrizzontale(fa.id) }
                            ChipSelezione("Offset −", "minus") { model.offsetPiano(fa.id, verso: -1) }
                            ChipSelezione("Offset +", "plus") { model.offsetPiano(fa.id, verso: 1) }
                            ChipSelezione("Allinea facciata", "link") { model.allineaAllaFacciata(fa.id) }
                            ChipSelezione("Fitta mesh", "scope") { model.fittaSelezionateAllaMesh() }
                            Divider().frame(height: 16)
                            ChipSelezione("Cima +", "arrow.up.to.line") { model.regolaAltezzaSelezionate(cima: true, verso: 1) }
                            ChipSelezione("Cima −", "arrow.down.to.line") { model.regolaAltezzaSelezionate(cima: true, verso: -1) }
                            ChipSelezione("Base +", "arrow.up") { model.regolaAltezzaSelezionate(cima: false, verso: 1) }
                            ChipSelezione("Base −", "arrow.down") { model.regolaAltezzaSelezionate(cima: false, verso: -1) }
                        }
                    }
                }
            }
            // 4 · PASTIGLIE dei piani — tocca per renderne uno attivo
            if !model.facce.isEmpty {
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if model.facce.contains(where: { $0.nascosto }) {
                                Button { model.mostraTuttiIPiani() } label: {
                                    Label("Mostra tutti", systemImage: "eye")
                                        .font(Theme.Typo.caption(10, .semibold))
                                        .foregroundStyle(EditorTheme.testo)
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            ForEach(model.facce) { f in
                                HStack(spacing: 5) {
                                    Button { model.toggleVisibilitaFaccia(f.id) } label: {
                                        Image(systemName: f.nascosto ? "eye.slash" : "eye")
                                            .font(.system(size: 11))
                                            .foregroundStyle(f.nascosto ? EditorTheme.testoMuto : EditorTheme.testo)
                                    }
                                    Button { model.selezionaFacciaAttiva(f.id) } label: {
                                        HStack(spacing: 5) {
                                            Circle().fill(Color(uiColor: f.colore)).frame(width: 9, height: 9)
                                            Text("\(f.nome) · \(f.triangoli.count)")
                                                .font(Theme.Typo.caption(10, .semibold))
                                                .foregroundStyle(EditorTheme.testo)
                                        }
                                    }
                                }
                                .opacity(f.nascosto ? 0.45 : 1)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(model.facceSelezionate.contains(f.id) ? EditorTheme.accento.opacity(0.35)
                                            : (f.id == model.facciaAttivaId ? EditorTheme.accento.opacity(0.25) : EditorTheme.panelAlt),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(model.facceSelezionate.contains(f.id) ? EditorTheme.accento : .clear, lineWidth: 1.5))
                            }
                        }
                    }
                    Menu {
                        ForEach(StatoProxy.allCases) { s in
                            Button(s.etichetta) { model.statoProxy = s }
                        }
                    } label: {
                        Text(model.statoProxy.etichetta)
                            .font(Theme.Typo.caption(10, .semibold))
                            .foregroundStyle(EditorTheme.testoMuto)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var suggerimentoPiani: String {
        switch model.modoSelezione {
        case .seleziona:  return "tocca un piano per selezionarlo e modificarlo"
        case .tocco:      return "tocca ogni superficie per un seme, poi Genera piani"
        case .pennello:   return "pennella le superfici, poi Genera piani"
        case .rettangolo: return "trascina un rettangolo sulle superfici, poi Genera piani"
        case .lazo:       return "circonda le superfici col lazo, poi Genera piani"
        case .poligonale: return "tocca i vertici del poligono, chiudi e poi elimina o genera"
        }
    }

    private var barraBox: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(model.modoSelezione == .poligonale ? "Tocca i vertici del lazo, poi elimina" : "Trascina le maniglie, poi ritaglia")
                    .font(Theme.Typo.caption(11))
                    .foregroundStyle(EditorTheme.testoMuto)
                Spacer()
                ChipSelezione("Allinea", "cube.transparent") { model.allineaBox() }
                ChipSelezione("Reset", "arrow.counterclockwise") { model.resetBox() }
                ChipSelezione("Inverti", "rectangle.righthalf.inset.filled") { model.applicaCrop(inverti: true) }
                Button { model.applicaCrop(inverti: false) } label: {
                    Label("Ritaglia", systemImage: "crop")
                        .font(Theme.Typo.caption(12, .bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(EditorTheme.accento, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
            }
            HStack(spacing: 8) {
                Button {
                    if model.modoSelezione == .poligonale {
                        model.resetLazoPoligonale()
                        model.modoSelezione = .seleziona
                    } else {
                        model.deselezionaTutto()
                        model.modoSelezione = .poligonale
                    }
                } label: {
                    Label("Lazo poly", systemImage: "skew")
                        .font(Theme.Typo.caption(11, .semibold))
                        .foregroundStyle(model.modoSelezione == .poligonale ? .white : EditorTheme.testo)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(model.modoSelezione == .poligonale ? EditorTheme.accento : EditorTheme.panelAlt,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                if model.modoSelezione == .poligonale {
                    Text(model.numPuntiLazoPoligonale == 0 ? "nessun punto" : "\(model.numPuntiLazoPoligonale) punti")
                        .font(Theme.Typo.mono(10))
                        .foregroundStyle(EditorTheme.testoMuto)
                    ChipSelezione("Chiudi", "checkmark.circle") { model.chiudiLazoPoligonale() }
                        .disabled(model.numPuntiLazoPoligonale < 3)
                        .opacity(model.numPuntiLazoPoligonale < 3 ? 0.45 : 1)
                    ChipSelezione("Annulla", "xmark.circle") { model.resetLazoPoligonale() }
                    if model.numSelezionati > 0 {
                        ChipSelezione("Elimina mesh (\(model.numSelezionati))", "trash") { model.eliminaSelezione() }
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
    }


    /// Controlli del pennello: dimensione + vincolo alle normali con tolleranza.
    private var controlliPennello: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed").font(.system(size: 12))
                    .foregroundStyle(EditorTheme.testoMuto)
                Slider(value: Binding(get: { Double(model.raggioPennello) },
                                      set: { model.raggioPennello = CGFloat($0) }), in: 12...110)
                    .tint(EditorTheme.accento)
                Text("\(Int(model.raggioPennello)) px").font(Theme.Typo.mono(10))
                    .foregroundStyle(EditorTheme.testoMuto).frame(width: 40, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Button { model.vincolaNormali.toggle() } label: {
                    Label("Vincola normali", systemImage: model.vincolaNormali ? "checkmark.square.fill" : "square")
                        .font(Theme.Typo.caption(11, .semibold))
                        .foregroundStyle(model.vincolaNormali ? EditorTheme.accento : EditorTheme.testo)
                }
                if model.vincolaNormali {
                    Slider(value: $model.tolleranzaNormaleGradi, in: 5...80).tint(EditorTheme.accento)
                    Text("±\(Int(model.tolleranzaNormaleGradi))°").font(Theme.Typo.mono(10))
                        .foregroundStyle(EditorTheme.testoMuto).frame(width: 40, alignment: .trailing)
                } else {
                    Spacer()
                }
            }
        }
    }

    private var suggerimentoPunti: String {
        switch model.numPuntiFaccia {
        case 0:  return "Tocca 3+ punti sul muro a livello zero"
        case 1, 2: return "\(model.numPuntiFaccia) punti · servono ≥3"
        default: return "\(model.numPuntiFaccia) punti · calcola il piano"
        }
    }
}

// MARK: – ViewCube di navigazione (alto-destra, stile 3ds Max)

private struct NavGizmo: View {
    @ObservedObject var model: Mesh3DModel
    var body: some View {
        VStack(spacing: 5) {
            ViewCubeMini(model: model)
                .frame(width: 64, height: 64)
                .accessibilityLabel("Cubo di navigazione")
            HStack(spacing: 4) {
                gizIcon(
                    model.autoRuota ? "pause.fill" : "arrow.triangle.2.circlepath",
                    attivo: model.autoRuota,
                    aiuto: model.autoRuota ? "Ferma rotazione" : "Rotazione automatica"
                ) { model.toggleAutoRuota() }
                gizIcon("viewfinder", aiuto: "Vista frontale") { model.snapFronte() }
                gizIcon("cube", aiuto: "Vista isometrica") { model.snapIso() }
                Menu {
                    Button("Fronte", systemImage: "rectangle") { model.snapFronte() }
                    Button("Retro", systemImage: "rectangle") { model.snapRetro() }
                    Divider()
                    Button("Sinistra", systemImage: "arrow.left") { model.snapSinistra() }
                    Button("Destra", systemImage: "arrow.right") { model.snapDestra() }
                    Divider()
                    Button("Alto", systemImage: "arrow.up") { model.snapAlto() }
                    Button("Basso", systemImage: "arrow.down") { model.snapBasso() }
                } label: {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(EditorTheme.panelAlt,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(EditorTheme.testo)
                }
                .accessibilityLabel("Altre viste")
            }
        }
        .padding(6)
        .background(EditorTheme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(EditorTheme.hair, lineWidth: 1))
    }
    private func gizIcon(
        _ icona: String,
        attivo: Bool = false,
        aiuto: String,
        _ azione: @escaping () -> Void
    ) -> some View {
        Button(action: azione) {
            Image(systemName: icona)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(attivo ? EditorTheme.accento : EditorTheme.panelAlt,
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(attivo ? .white : EditorTheme.testo)
        }
        .help(aiuto)
        .accessibilityLabel(aiuto)
    }
}

/// Cubetto 3D che rispecchia l'orientamento della camera; tap su una faccia →
/// snap a quella vista.
private struct ViewCubeMini: UIViewRepresentable {
    @ObservedObject var model: Mesh3DModel
    func makeCoordinator() -> Coord { Coord(model) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .clear
        v.scene = SCNScene()
        let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.08)
        box.materials = Self.facce()
        let cube = SCNNode(geometry: box); cube.name = "cube"
        v.scene!.rootNode.addChildNode(cube)

        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.camera!.usesOrthographicProjection = true
        cam.camera!.orthographicScale = 0.95
        cam.position = SCNVector3(0, 0, 4)
        v.scene!.rootNode.addChildNode(cam); v.pointOfView = cam
        let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 600
        v.scene!.rootNode.addChildNode(amb)
        let dir = SCNNode(); dir.light = SCNLight(); dir.light!.type = .directional
        dir.eulerAngles = SCNVector3(-0.6, 0.5, 0); v.scene!.rootNode.addChildNode(dir)

        context.coordinator.cube = cube; context.coordinator.view = v
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coord.tap(_:)))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        // Il cubo mostra il frame editor (facciata/modello), non gli assi mondo.
        // Cosi' i pulsanti F/A/D e quello che vedi nel navigatore sono coerenti.
        context.coordinator.cube?.simdOrientation = model.cameraQuat.inverse * model.quatFrameNavigazione()
    }

    /// 6 facce etichettate (ordine SCNBox: +Z,+X,-Z,-X,+Y,-Y).
    static func facce() -> [SCNMaterial] {
        let rosso = UIColor(red: 0.86, green: 0.30, blue: 0.27, alpha: 1)
        let verde = UIColor(red: 0.30, green: 0.66, blue: 0.38, alpha: 1)
        let blu   = UIColor(red: 0.27, green: 0.55, blue: 0.84, alpha: 1)
        return [("F", blu), ("D", rosso), ("R", blu), ("S", rosso), ("A", verde), ("B", verde)]
            .map { etichetta($0.0, $0.1) }
    }
    private static func etichetta(_ s: String, _ bg: UIColor) -> SCNMaterial {
        let size = CGSize(width: 128, height: 128)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            bg.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let attr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 60, weight: .bold),
                .foregroundColor: UIColor.white, .paragraphStyle: p]
            (s as NSString).draw(in: CGRect(x: 0, y: 30, width: 128, height: 80), withAttributes: attr)
        }
        let m = SCNMaterial(); m.diffuse.contents = img; m.lightingModel = .blinn
        return m
    }

    final class Coord: NSObject {
        let model: Mesh3DModel
        weak var view: SCNView?
        weak var cube: SCNNode?
        init(_ model: Mesh3DModel) { self.model = model }

        @MainActor @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            let hits = v.hitTest(g.location(in: v), options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .categoryBitMask: 1,
            ])
            guard let h = hits.first else { return }
            let ln = h.localNormal   // normale locale del cubo ≈ ±asse
            let n = SIMD3<Float>(Float(ln.x), Float(ln.y), Float(ln.z))
            let ax = [abs(n.x), abs(n.y), abs(n.z)]
            let idx = ax[0] >= ax[1] && ax[0] >= ax[2] ? 0 : (ax[1] >= ax[2] ? 1 : 2)
            let segno: Float = [n.x, n.y, n.z][idx] >= 0 ? 1 : -1
            model.snapAsse(idx, segno)
        }
    }
}

/// Share sheet per i JSON proxy esportati.
private struct CondivisioneMesh: UIViewControllerRepresentable {
    let elementi: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: elementi, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Chip d'azione per le operazioni di selezione.
private struct ChipSelezione: View {
    let titolo: String
    let icona: String
    let azione: () -> Void
    init(_ titolo: String, _ icona: String, _ azione: @escaping () -> Void) {
        self.titolo = titolo; self.icona = icona; self.azione = azione
    }
    var body: some View {
        Button(action: azione) {
            Label(titolo, systemImage: icona)
                .font(Theme.Typo.caption(11, .semibold))
                .foregroundStyle(EditorTheme.testo)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(EditorTheme.panelAlt, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Pulsante strumento 3D (zona pollice, 44pt), stile coerente con l'editor 2D.
private struct PulsanteStrumento3D: View {
    let strumento: StrumentoMesh3D
    let attivo: Bool
    let azione: () -> Void

    var body: some View {
        Button(action: azione) {
            VStack(spacing: 2) {
                Image(systemName: strumento.icona)
                    .font(.system(size: 16, weight: .medium))
                Text(strumento.etichetta)
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(attivo ? .white : EditorTheme.testo)
            .frame(width: 60, height: 44)
            .background(attivo ? EditorTheme.accento : EditorTheme.panelAlt,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityLabel(strumento.etichetta)
    }
}

// MARK: – Container SceneKit (UIKit)

/// Wrapper di `SCNView` con orbit/pan/zoom integrati (defaultCameraController).
/// L'inquadratura usa `frameNodes(_:)` del camera controller — più affidabile
/// di una camera piazzata a mano sotto `allowsCameraControl`.
private struct SceneKitContainer: UIViewRepresentable {
    @ObservedObject var model: Mesh3DModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = model.scene
        v.allowsCameraControl = true          // orbit / pan / pinch-zoom (il tap resta libero)
        v.autoenablesDefaultLighting = false  // solo le nostre luci (directional+ambient)
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.backgroundColor = UIColor(EditorTheme.bg)
        v.antialiasingMode = .none
        v.preferredFramesPerSecond = 60
        context.coordinator.view = v

        // Tap = aggiunge un punto della faccia (solo in modalità .punti).
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        v.addGestureRecognizer(tap)

        // Pan = lazo di selezione (abilitato solo in modalità .seleziona).
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        v.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        // Pinch = zoom camera gestito da noi. Sul simulatore iPad dal trackpad del
        // Mac il controller SceneKit non riceve sempre il pinch in modo affidabile.
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        pinch.isEnabled = true
        pinch.delegate = context.coordinator
        v.addGestureRecognizer(pinch)
        context.coordinator.pinch = pinch

        let cameraPan = UIPanGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleCameraPanMonitor(_:)))
        cameraPan.maximumNumberOfTouches = 1
        cameraPan.cancelsTouchesInView = false
        cameraPan.delegate = context.coordinator
        v.addGestureRecognizer(cameraPan)

        let hover = UIHoverGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleHover(_:)))
        hover.delegate = context.coordinator
        v.addGestureRecognizer(hover)

        let lasso = CAShapeLayer()
        lasso.fillColor = UIColor(EditorTheme.accento).withAlphaComponent(0.15).cgColor
        lasso.strokeColor = UIColor(EditorTheme.accento).cgColor
        lasso.lineWidth = 1.5
        lasso.lineDashPattern = [6, 4]
        v.layer.addSublayer(lasso)
        context.coordinator.lassoLayer = lasso
        v.delegate = context.coordinator   // per leggere l'orientamento camera (ViewCube)
        // Snap vista: callback diretto (affidabile anche a scena ferma).
        model.richiediSnap = { [weak v, weak model] dir, up in
            guard let v, let model else { return }
            Self.orientaCamera(v, contentNode: model.nodoDaInquadrare,
                               dir: dir, up: up,
                               ortografica: model.visteOrtografiche)
        }
        model.richiediZoom = { [weak v, weak model] fattore in
            guard let v, let model else { return }
            Self.zoomCamera(v, contentNode: model.nodoDaInquadrare, fattore: fattore)
        }
        model.richiediProspettiva = { [weak v, weak model] in
            guard let v, let model else { return }
            Self.usaProspettiva(v, contentNode: model.nodoDaInquadrare)
        }
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        // In .seleziona/.box/.facce il pan è nostro: spegni la camera.
        let panNostro = model.strumento == .seleziona || model.strumento == .box
            || model.strumento == .facce || model.strumento == .assi || model.strumento == .allinea
        v.allowsCameraControl = !panNostro
        context.coordinator.pan?.isEnabled = panNostro
        context.coordinator.pinch?.isEnabled = true
        context.coordinator.syncLazoPoligonale(in: v)

        if context.coordinator.lastTick != model.reframeTick {
            context.coordinator.lastTick = model.reframeTick
            let node = model.nodoDaInquadrare
            DispatchQueue.main.async { v.defaultCameraController.frameNodes([node]) }
        }
    }

    /// Orienta la camera lungo `dir` inquadrando la mesh (chiamato dallo snap).
    static func orientaCamera(_ v: SCNView, contentNode: SCNNode,
                              dir: SIMD3<Float>, up: SIMD3<Float>,
                              ortografica: Bool) {
        // Bounds della SOLA mesh (la geometria di contentNode), non dei figli:
        // flattenedClone includeva nodi enormi/overlay e mandava la camera lontano.
        let bb = contentNode.boundingBox
        let lo = SIMD3<Float>(bb.min.x, bb.min.y, bb.min.z)
        let hi = SIMD3<Float>(bb.max.x, bb.max.y, bb.max.z)
        let center = contentNode.simdConvertPosition((lo + hi) * 0.5, to: nil)
        let diag = max(simd_length(hi - lo), 1e-3)
        let dirN = simd_normalize(dir)
        let upN = simd_normalize(up)
        let dist = diag * 2.0
        let eye = center + dirN * dist
        let m = lookAt(eye: eye, center: center, up: upN)

        let f = simd_normalize(center - eye)
        var right = simd_cross(f, upN)
        if simd_length(right) < 1e-5 { right = simd_cross(f, SIMD3<Float>(1, 0, 0)) }
        right = simd_normalize(right)
        let camUp = simd_normalize(simd_cross(right, f))
        let corners = [
            SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z),
            SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z),
            SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z),
            SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z)
        ]
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for c0 in corners {
            let c = contentNode.simdConvertPosition(c0, to: nil)
            let d = c - center
            let x = simd_dot(d, right)
            let y = simd_dot(d, camUp)
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let aspect = max(Float(v.bounds.width / max(v.bounds.height, 1)), 0.1)
        let scalaY = max(maxY - minY, (maxX - minX) / aspect, diag * 0.05) * 1.12

        let nodo: SCNNode
        if let esistente = v.scene?.rootNode.childNode(withName: "snapCam", recursively: false) {
            nodo = esistente
        } else {
            nodo = SCNNode(); nodo.name = "snapCam"; nodo.camera = SCNCamera()
            v.scene?.rootNode.addChildNode(nodo)
        }
        nodo.camera?.usesOrthographicProjection = ortografica
        if ortografica {
            nodo.camera?.orthographicScale = Double(scalaY)
        } else {
            nodo.camera?.fieldOfView = 55
        }
        nodo.camera?.zNear = max(0.01, Double(diag) * 0.002)
        nodo.camera?.zFar = Double(dist + diag) * 4
        nodo.simdTransform = m
        v.pointOfView = nodo
    }

    static func usaProspettiva(_ v: SCNView, contentNode: SCNNode) {
        guard let cam = v.pointOfView?.camera,
              cam.usesOrthographicProjection else { return }
        cam.usesOrthographicProjection = false
        cam.fieldOfView = 55
        let bs = contentNode.boundingSphere
        let ext = max(bs.radius * 2, 1e-3)
        cam.zNear = max(0.001, Double(ext) * 0.0005)
        cam.zFar = max(cam.zFar, Double(ext) * 8)
    }

    static func zoomCamera(_ v: SCNView, contentNode: SCNNode, fattore: Float) {
        guard let pov = v.pointOfView, fattore > 0.001 else { return }
        if pov.camera?.usesOrthographicProjection == true {
            let current = pov.camera?.orthographicScale ?? 1
            pov.camera?.orthographicScale = max(0.001, current / Double(fattore))
            return
        }
        let bs = contentNode.boundingSphere
        let center = contentNode.simdConvertPosition(
            SIMD3<Float>(bs.center.x, bs.center.y, bs.center.z), to: nil)
        let ext = max(bs.radius * 2, 1e-3)
        let pos = pov.simdWorldPosition
        var dir = pos - center
        var dist = simd_length(dir)
        guard dist > 1e-5 else { return }
        dir /= dist
        dist /= fattore
        dist = max(ext * 0.03, min(ext * 12, dist))
        pov.simdWorldPosition = center + dir * dist
        pov.camera?.zNear = max(0.001, Double(ext) * 0.0005)
        pov.camera?.zFar = max(pov.camera?.zFar ?? 1000, Double(dist + ext) * 4)
    }

    /// Matrice di vista (camera SceneKit guarda lungo -Z).
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        var s = simd_cross(f, up)
        if simd_length(s) < 1e-5 { s = simd_cross(f, SIMD3<Float>(1, 0, 0)) }
        s = simd_normalize(s)
        let u = simd_cross(s, f)
        let zc = -f
        return simd_float4x4(
            SIMD4<Float>(s.x, s.y, s.z, 0),
            SIMD4<Float>(u.x, u.y, u.z, 0),
            SIMD4<Float>(zc.x, zc.y, zc.z, 0),
            SIMD4<Float>(eye.x, eye.y, eye.z, 1))
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate, UIGestureRecognizerDelegate {
        let model: Mesh3DModel
        weak var view: SCNView?
        weak var pan: UIPanGestureRecognizer?
        weak var pinch: UIPinchGestureRecognizer?
        var lassoLayer: CAShapeLayer?
        var lastTick = -1
        var lastSnap = 0
        private var lassoPunti: [CGPoint] = []
        private var lazoPoligonalePunti: [CGPoint] = []
        private var lastLazoResetTick = 0
        private var lastLazoApplyTick = 0
        private var ultimoQuat = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        private var puntoAssiInDrag: Int?
        // Fase C: maniglia del poligono in trascinamento.
        private struct Trascina {
            let faccia: Int; let edge: Bool; let k: Int
            let p: SIMD3<Float>; let n: SIMD3<Float>
            let start: SIMD3<Float>; let orig: [SIMD3<Float>]
            let asse: SIMD3<Float>?
            let startAsse: Float?
        }
        private var trascina: Trascina?

        init(_ model: Mesh3DModel) { self.model = model }

        /// Intersezione del raggio dello schermo `sp` col piano (p,n). Per il drag.
        @MainActor private func puntoSulPiano(_ sp: CGPoint, p: SIMD3<Float>, n: SIMD3<Float>, in v: SCNView) -> SIMD3<Float>? {
            let r = raggioSchermo(sp, in: v)
            let o = r.o
            let d = r.d
            let den = simd_dot(d, n)
            if abs(den) < 1e-6 { return nil }
            let t = simd_dot(p - o, n) / den
            return t >= 0 ? o + d * t : nil
        }

        @MainActor private func raggioSchermo(_ sp: CGPoint, in v: SCNView) -> (o: SIMD3<Float>, d: SIMD3<Float>) {
            let a = v.unprojectPoint(SCNVector3(Float(sp.x), Float(sp.y), 0))
            let b = v.unprojectPoint(SCNVector3(Float(sp.x), Float(sp.y), 1))
            let o = SIMD3<Float>(a.x, a.y, a.z)
            let d = simd_normalize(SIMD3<Float>(b.x - a.x, b.y - a.y, b.z - a.z))
            return (o, d)
        }

        @MainActor private func parametroAsseDaTouch(_ sp: CGPoint,
                                                     puntoAsse: SIMD3<Float>,
                                                     asse: SIMD3<Float>,
                                                     in v: SCNView) -> Float? {
            let r = raggioSchermo(sp, in: v)
            let a = simd_normalize(asse)
            let b = simd_dot(a, r.d)
            let denom = max(1 - b * b, 0)
            guard denom > 1e-5 else { return nil }
            let w0 = puntoAsse - r.o
            let d1 = simd_dot(a, w0)
            let d2 = simd_dot(r.d, w0)
            return (b * d2 - d1) / denom
        }

        /// Maniglia (angolo "maniglia:f:k" o edge "edge:f:k") sotto `sp`, se c'è.
        @MainActor private func maniglia(sotto sp: CGPoint, in v: SCNView) -> (faccia: Int, edge: Bool, k: Int)? {
            let hits = v.hitTest(sp, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .categoryBitMask: 1,
            ])
            for h in hits {
                var nodo: SCNNode? = h.node
                var nome: String?
                while let cur = nodo {
                    if let nm = cur.name, nm.hasPrefix("maniglia:") || nm.hasPrefix("edge:") {
                        nome = nm
                        break
                    }
                    nodo = cur.parent
                }
                guard let nm = nome else { continue }
                let parti = nm.split(separator: ":")
                guard parti.count == 3, let fid = Int(parti[1]), let k = Int(parti[2]) else { continue }
                if parti[0] == "maniglia" { return (fid, false, k) }
                if parti[0] == "edge" { return (fid, true, k) }
            }
            return nil
        }

        // Mirror dell'orientamento camera → ViewCube (throttle se cambia poco).
        nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let pov = renderer.pointOfView else { return }
            let q = pov.simdOrientation
            Task { @MainActor in self.aggiornaQuat(q) }
        }

        @MainActor private func aggiornaQuat(_ q: simd_quatf) {
            let d = abs(simd_dot(q.vector, ultimoQuat.vector))
            if d < 0.9999 {   // ~ aggiorna solo se l'orientamento è cambiato
                ultimoQuat = q
                model.cameraQuat = q
            }
        }

        @MainActor @objc func handleCameraPanMonitor(_ g: UIPanGestureRecognizer) {
            guard g.state == .began, model.strumento == .orbita else { return }
            model.tornaProspettivaPerRotazione()
        }

        @MainActor @objc func handleHover(_ g: UIHoverGestureRecognizer) {
            guard let v = view, model.strumento == .assi else { return }
            if g.state == .ended || g.state == .cancelled {
                model.aggiornaAnteprimaAssiManuali(nil)
                return
            }
            model.aggiornaAnteprimaAssiManuali(puntoMesh(sotto: g.location(in: v), in: v))
        }

        /// Zoom a due dita (dolly verso/da il centro mesh). Attivo solo quando
        /// `allowsCameraControl` è spento (Piani/Seleziona/Box).
        @MainActor @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard g.state == .began || g.state == .changed, let v = view else { return }
            let s = Float(g.scale); g.scale = 1
            guard s > 0.001 else { return }
            SceneKitContainer.zoomCamera(v, contentNode: model.contentNode, fattore: s)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @MainActor @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            let pt = g.location(in: v)
            // Rileva perimetro: il tracciamento avviene nel pannello 2D; sul 3D il
            // tap non fa nulla (si posiziona la sezione con lo slider, si ruota col pan).
            if model.modoPerimetro { return }
            // Naviga: il tap posa il mirino d'ispezione sulla mesh.
            if model.strumento == .orbita {
                let hits = v.hitTest(pt, options: [
                    .searchMode: SCNHitTestSearchMode.closest.rawValue,
                    .categoryBitMask: 1,
                ])
                if let h = hits.first(where: { $0.node === model.contentNode }) {
                    model.posizionaCursore(h.worldCoordinates, triangolo: h.faceIndex)
                }
                return
            }
            // Box: lazo poligonale di pulizia mesh.
            if model.strumento == .box && model.modoSelezione == .poligonale {
                aggiungiPuntoLazoPoligonale(pt, in: v)
                return
            }
            if model.strumento == .assi {
                let hits = v.hitTest(pt, options: [
                    .searchMode: SCNHitTestSearchMode.closest.rawValue,
                    .categoryBitMask: 1,
                ])
                if let h = hits.first(where: { $0.node === model.contentNode }) {
                    model.aggiungiPuntoAssiManuali(h.worldCoordinates)
                }
                return
            }
            if model.strumento == .allinea {
                // Fase "scegli sorgente": il prossimo tap definisce il punto sorgente.
                if model.attendoSorgenteAllinea {
                    if let m = maniglia(sotto: pt, in: v), !m.edge,
                       let p = model.posizioneVertice(faccia: m.faccia, k: m.k) {
                        model.allineaConSorgente(p)
                    } else {
                        let hits = v.hitTest(pt, options: [
                            .searchMode: SCNHitTestSearchMode.closest.rawValue,
                            .categoryBitMask: 1,
                        ])
                        if let h = hits.first(where: { $0.node === model.contentNode }) {
                            let w = h.worldCoordinates
                            model.allineaConSorgente(SIMD3<Float>(w.x, w.y, w.z))
                        }
                    }
                    return
                }
                // Selezione sub-elemento secondo il tipo attivo.
                switch model.tipoElemento {
                case .vertice:
                    if let m = maniglia(sotto: pt, in: v), !m.edge { model.toggleVerticeAllinea(faccia: m.faccia, k: m.k) }
                case .spigolo:
                    if let m = maniglia(sotto: pt, in: v), m.edge { model.toggleSpigoloAllinea(faccia: m.faccia, k: m.k) }
                case .faccia:
                    let tutti = v.hitTest(pt, options: [
                        .searchMode: SCNHitTestSearchMode.all.rawValue,
                        .categoryBitMask: 1,
                    ])
                    for hh in tutti {
                        if let nm = hh.node.name, nm.hasPrefix("piano:"), let id = Int(nm.dropFirst("piano:".count)) {
                            model.toggleFacciaAllinea(id); return
                        }
                    }
                    let hits = v.hitTest(pt, options: [
                        .searchMode: SCNHitTestSearchMode.closest.rawValue,
                        .categoryBitMask: 1,
                    ])
                    if let h = hits.first(where: { $0.node === model.contentNode }),
                       let g = model.facce.first(where: { $0.triangoli.contains(h.faceIndex) }) {
                        model.toggleFacciaAllinea(g.id)
                    }
                }
                return
            }
            // Revisione piani: ogni tap associa un riferimento al piano corrispondente.
            if model.strumento == .facce && model.attendePuntoZero {
                let hits = v.hitTest(pt, options: [
                    .searchMode: SCNHitTestSearchMode.closest.rawValue,
                    .categoryBitMask: 1,
                ])
                if let h = hits.first(where: { $0.node === model.contentNode }) {
                    model.aggiungiPuntoRevisione(h.worldCoordinates, triangolo: h.faceIndex)
                }
                return
            }
            // Piani: maniglia edge → splitta; piano esistente → selezionalo;
            // altrimenti, in modo "tocco", lascia un seme (cresce dopo con Genera).
            if model.strumento == .facce {
                if model.modoSelezione == .poligonale {
                    aggiungiPuntoLazoPoligonale(pt, in: v)
                    return
                }
                if let m = maniglia(sotto: pt, in: v) {
                    model.selezionaManigliaPoligono(faccia: m.faccia, edge: m.edge, indice: m.k)
                    model.ciclaAsseMovimentoPoligono()
                    return
                }
                // Piano solo-poligono (es. facciata estrusa): selezionabile dal suo
                // riempimento "piano:<id>".
                let tutti = v.hitTest(pt, options: [
                    .searchMode: SCNHitTestSearchMode.all.rawValue,
                    .categoryBitMask: 1,
                ])
                for hh in tutti {
                    if let nm = hh.node.name, nm.hasPrefix("piano:"),
                       let id = Int(nm.dropFirst("piano:".count)) {
                        model.selezionaFacciaAttiva(id); return
                    }
                }
                let hits = v.hitTest(pt, options: [
                    .searchMode: SCNHitTestSearchMode.closest.rawValue,
                    .categoryBitMask: 1,
                ])
                guard let h = hits.first(where: { $0.node === model.contentNode }) else { return }
                if let g = model.facce.first(where: { $0.triangoli.contains(h.faceIndex) }) {
                    model.selezionaFacciaAttiva(g.id)
                } else if model.modoSelezione == .tocco {
                    let w = h.worldCoordinates
                    model.aggiungiSeme(triangolo: h.faceIndex, punto: SIMD3<Float>(w.x, w.y, w.z))
                }
                return
            }
            guard model.strumento == .punti else { return }
            let hits = v.hitTest(pt, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: true,
                .categoryBitMask: 1,
            ])
            for h in hits where discendente(h.node, di: model.contentNode) {
                model.aggiungiPunto(h.worldCoordinates)
                return
            }
        }

        // Proiezioni schermo dei baricentri, calcolate UNA volta a inizio gesto
        // (in selezione la camera è ferma → si riusano per tutto il gesto).
        private var cacheSchermo: [(i: Int, p: CGPoint)] = []
        private var rettInizio: CGPoint?
        private var refNormale: SIMD3<Float>?   // normale sotto il dito a inizio pennellata
        @MainActor private var raggioPennello: CGFloat { model.raggioPennello }

        /// Normale del triangolo colpito sotto `p` (riferimento del vincolo).
        @MainActor private func catturaNormaleRif(_ p: CGPoint, in v: SCNView) {
            let hits = v.hitTest(p, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .categoryBitMask: 1,
            ])
            if let h = hits.first(where: { $0.node === model.contentNode }) {
                refNormale = model.mesh.normale(h.faceIndex)
            } else {
                refNormale = nil
            }
        }

        /// Il triangolo `i` passa il vincolo normali rispetto al riferimento?
        @MainActor private func passaNormale(_ i: Int) -> Bool {
            guard model.vincolaNormali, let ref = refNormale else { return true }
            let cosTol = Float(cos(model.tolleranzaNormaleGradi * .pi / 180))
            return abs(simd_dot(model.mesh.normale(i), ref)) >= cosTol
        }

        @MainActor private func puntoMesh(sotto p: CGPoint, in v: SCNView) -> SCNVector3? {
            let hits = v.hitTest(p, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .categoryBitMask: 1,
            ])
            return hits.first(where: { $0.node === model.contentNode })?.worldCoordinates
        }

        @MainActor private func puntoAssiVicino(_ p: CGPoint, in v: SCNView) -> Int? {
            var best: (i: Int, d: CGFloat)?
            for (i, w) in model.puntiAssiManuali.enumerated() {
                let sp = v.projectPoint(SCNVector3(w.x, w.y, w.z))
                guard sp.z >= 0, sp.z <= 1 else { continue }
                let d = hypot(CGFloat(sp.x) - p.x, CGFloat(sp.y) - p.y)
                if d < 28, best == nil || d < best!.d {
                    best = (i, d)
                }
            }
            return best?.i
        }

        @MainActor private func handlePanAssi(_ g: UIPanGestureRecognizer, in v: SCNView) {
            let p = g.location(in: v)
            switch g.state {
            case .began:
                if let i = puntoAssiVicino(p, in: v) {
                    puntoAssiInDrag = i
                    if let w = puntoMesh(sotto: p, in: v) { model.muoviPuntoAssiManuali(indice: i, punto: w) }
                } else if model.puntiAssiManuali.count == 1 || model.puntiAssiManuali.count == 3 {
                    model.iniziaLineaAssiDaUltimoPunto()
                    if let w = puntoMesh(sotto: p, in: v) { model.aggiornaLineaAssiManuali(w) }
                } else if let w = puntoMesh(sotto: p, in: v) {
                    model.iniziaLineaAssiManuali(w)
                }
            case .changed:
                if let i = puntoAssiInDrag {
                    if let w = puntoMesh(sotto: p, in: v) { model.muoviPuntoAssiManuali(indice: i, punto: w) }
                } else if let w = puntoMesh(sotto: p, in: v) {
                    model.aggiornaLineaAssiManuali(w)
                }
            case .ended, .cancelled:
                if let i = puntoAssiInDrag {
                    if let w = puntoMesh(sotto: p, in: v) { model.muoviPuntoAssiManuali(indice: i, punto: w) }
                    puntoAssiInDrag = nil
                } else if let w = puntoMesh(sotto: p, in: v) {
                    model.confermaLineaAssiManuali(w)
                } else {
                    model.annullaLineaAssiManuali()
                }
            default:
                break
            }
        }

        private var panStartAllinea: CGPoint?
        private var spostaPianoP: SIMD3<Float>?
        private var spostaPianoN: SIMD3<Float>?
        private var spostaLastWorld: SIMD3<Float>?

        /// Selezione a rettangolo dei sub-elementi (vertici/spigoli/facce) per Allinea.
        @MainActor private func handlePanAllinea(_ g: UIPanGestureRecognizer, in v: SCNView) {
            if model.attendoSorgenteAllinea { return }   // in attesa sorgente: usa il tap
            let p = g.location(in: v)
            // Modalità SPOSTA: trascina per traslare la selezione (vincolata agli assi).
            if model.spostaAllinea && model.numElementiSel > 0 {
                switch g.state {
                case .began:
                    guard let c = model.centroideSelezioneAllinea(), let pov = v.pointOfView else { return }
                    let col = pov.simdWorldTransform.columns.2
                    let fwd = -simd_normalize(SIMD3<Float>(col.x, col.y, col.z))
                    spostaPianoP = c; spostaPianoN = fwd
                    spostaLastWorld = puntoSulPiano(p, p: c, n: fwd, in: v)
                    model.iniziaSpostamentoAllinea()
                case .changed:
                    guard let pp = spostaPianoP, let nn = spostaPianoN, let last = spostaLastWorld,
                          let w = puntoSulPiano(p, p: pp, n: nn, in: v) else { return }
                    let step = model.vincolaDeltaAllinea(w - last)
                    spostaLastWorld = w
                    model.spostaSelezioneAllinea(delta: step)
                case .ended, .cancelled:
                    spostaPianoP = nil; spostaPianoN = nil; spostaLastWorld = nil
                    model.concludiModificaPersistente()
                default: break
                }
                return
            }
            switch g.state {
            case .began:
                panStartAllinea = p
                lassoLayer?.isHidden = false
            case .changed:
                guard let s = panStartAllinea else { return }
                let rect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
                lassoLayer?.path = CGPath(rect: rect, transform: nil)
            case .ended, .cancelled:
                lassoLayer?.isHidden = true
                lassoLayer?.path = nil
                defer { panStartAllinea = nil }
                guard let s = panStartAllinea else { return }
                let rect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
                guard rect.width > 4, rect.height > 4 else { return }   // tap: lascialo al tap handler
                func proj(_ q: SIMD3<Float>) -> CGPoint {
                    let pr = v.projectPoint(SCNVector3(q.x, q.y, q.z)); return CGPoint(x: CGFloat(pr.x), y: CGFloat(pr.y))
                }
                var vert: [ElemId] = [], spig: [ElemId] = [], facc: [Int] = []
                for f in model.facce {
                    guard let poly = f.poligono, !poly.isEmpty else { continue }
                    switch model.tipoElemento {
                    case .vertice:
                        for k in poly.indices where rect.contains(proj(poly[k])) { vert.append(ElemId(faccia: f.id, k: k)) }
                    case .spigolo:
                        for k in poly.indices {
                            let a = proj(poly[k]), b = proj(poly[(k + 1) % poly.count])
                            if rect.contains(a) && rect.contains(b) { spig.append(ElemId(faccia: f.id, k: k)) }
                        }
                    case .faccia:
                        let c = poly.reduce(SIMD3<Float>(0,0,0), +) / Float(poly.count)
                        if rect.contains(proj(c)) { facc.append(f.id) }
                    }
                }
                model.aggiungiSelezioneAllinea(vertici: vert, spigoli: spig, facce: facc)
            default: break
            }
        }

        @MainActor @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = view else { return }
            if model.strumento == .box { handlePanBox(g, in: v); return }
            if model.strumento == .facce { handlePanFacce(g, in: v); return }
            if model.strumento == .assi { handlePanAssi(g, in: v); return }
            if model.strumento == .allinea { handlePanAllinea(g, in: v); return }
            let p = g.location(in: v)
            switch g.state {
            case .began:
                proiettaCentroidi(in: v)
                catturaNormaleRif(p, in: v)
                rettInizio = p
                lassoPunti = [p]
                if model.modoSelezione == .pennello { model.applicaLazo([], aggiungi: false); pennella(p) }
            case .changed:
                switch model.modoSelezione {
                case .lazo:
                    lassoPunti.append(p); aggiornaTracciato(chiusa: true)
                case .rettangolo:
                    aggiornaRettangolo(da: rettInizio ?? p, a: p)
                case .pennello:
                    pennella(p); disegnaCerchioPennello(p)
                case .tocco, .seleziona, .poligonale:
                    break
                }
            case .ended, .cancelled:
                switch model.modoSelezione {
                case .lazo:
                    aggiornaTracciato(chiusa: true)
                    if lassoPunti.count >= 3 { selezionaDaPoligono(lassoPunti) }
                case .rettangolo:
                    if let a = rettInizio { selezionaDaRettangolo(a, p) }
                case .pennello, .tocco, .seleziona:
                    break   // selezione già applicata in continuo / nessun pan
                case .poligonale:
                    break
                }
                lassoPunti = []; rettInizio = nil; cacheSchermo = []
                lassoLayer?.path = nil
            default:
                break
            }
        }

        /// Proietta tutti i baricentri dei triangoli in coordinate schermo.
        // z-buffer grezzo per la selezione: distanza minima dalla camera per cella
        // schermo → si tiene solo il layer frontale (no facce dietro/occluse).
        private var depthGrid: [Int: Float] = [:]
        private var depthTol: Float = 1
        private let cellaPx: CGFloat = 14
        private func cella(_ p: CGPoint) -> Int { Int(p.y / cellaPx) &* 4096 &+ Int(p.x / cellaPx) }

        @MainActor private func proiettaCentroidi(in v: SCNView) {
            let tris = model.mesh.triangles
            let cam = v.pointOfView?.simdWorldPosition ?? SIMD3<Float>(0, 0, 0)
            var out: [(Int, CGPoint)] = []
            out.reserveCapacity(tris.count)
            depthGrid.removeAll(keepingCapacity: true)
            // tolleranza ~5% del lato mesh: assorbe lo spessore del muro, scarta il fondo
            depthTol = model.estensioneLato * 0.05
            for i in tris.indices {
                let c = model.mesh.centroid(tris[i])
                let sp = v.projectPoint(SCNVector3(c.x, c.y, c.z))
                guard sp.z > 0, sp.z < 1 else { continue }
                let p = CGPoint(x: CGFloat(sp.x), y: CGFloat(sp.y))
                let dist = simd_length(c - cam)
                out.append((i, p))
                let k = cella(p)
                if let m = depthGrid[k] { if dist < m { depthGrid[k] = dist } } else { depthGrid[k] = dist }
                // memorizza la distanza accanto allo screen point
                distCache[i] = dist
            }
            cacheSchermo = out
        }

        private var distCache: [Int: Float] = [:]

        /// True se il triangolo `i` (a schermo `p`) è nel layer frontale della sua cella.
        @MainActor private func visibile(_ i: Int, _ p: CGPoint) -> Bool {
            guard let d = distCache[i], let m = depthGrid[cella(p)] else { return true }
            return d <= m + depthTol
        }

        @MainActor private func selezionaDaPoligono(_ poly: [CGPoint]) {
            var sel = Set<Int>()
            for (i, sp) in cacheSchermo where puntoInPoligono(sp, poly) && visibile(i, sp) { sel.insert(i) }
            model.applicaLazo(sel, aggiungi: model.selezioneAdditiva)
        }

        @MainActor private func selezionaDaRettangolo(_ a: CGPoint, _ b: CGPoint) {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
            var sel = Set<Int>()
            for (i, sp) in cacheSchermo where r.contains(sp) && visibile(i, sp) { sel.insert(i) }
            model.applicaLazo(sel, aggiungi: model.selezioneAdditiva)
        }

        /// Pennello §3: assegna i triangoli sotto il dito alla faccia attiva.
        @MainActor private func handlePanFacce(_ g: UIPanGestureRecognizer, in v: SCNView) {
            let p = g.location(in: v)
            // Fase C: se un trascinamento di maniglia è in corso, muovi (delta dall'origine).
            if let tr = trascina {
                switch g.state {
                case .changed:
                    let delta: SIMD3<Float>?
                    if let asse = tr.asse, let startAsse = tr.startAsse,
                       let curAsse = parametroAsseDaTouch(p, puntoAsse: tr.start, asse: asse, in: v) {
                        delta = asse * (curAsse - startAsse)
                    } else if let cur = puntoSulPiano(p, p: tr.p, n: tr.n, in: v) {
                        delta = cur - tr.start
                    } else {
                        delta = nil
                    }
                    if let delta {
                        if tr.edge {
                            let k1 = (tr.k + 1) % tr.orig.count
                            model.spostaEdgePoligono(faccia: tr.faccia, edge: tr.k,
                                                     a: tr.orig[tr.k] + delta, tr.orig[k1] + delta)
                        } else {
                            model.spostaVerticePoligono(faccia: tr.faccia, indice: tr.k,
                                                        a: tr.orig[tr.k] + delta)
                        }
                    }
                case .ended, .cancelled:
                    trascina = nil
                    model.concludiModificaPersistente()
                default: break
                }
                return
            }
            // All'inizio di un pan: se parte su una maniglia, avvia il trascinamento.
            if g.state == .began, let m = maniglia(sotto: p, in: v),
               let pian = model.pianoFaccia(m.faccia), let orig = model.poligonoDi(m.faccia),
               let start = puntoSulPiano(p, p: pian.p, n: pian.n, in: v) {
                model.selezionaManigliaPoligono(faccia: m.faccia, edge: m.edge, indice: m.k)
                model.registraUndo()
                let asse = model.vettoreAsseMovimento(faccia: m.faccia)
                let startAsse = asse.flatMap { parametroAsseDaTouch(p, puntoAsse: start, asse: $0, in: v) }
                trascina = Trascina(faccia: m.faccia, edge: m.edge, k: m.k,
                                    p: pian.p, n: pian.n, start: start, orig: orig,
                                    asse: asse, startAsse: startAsse)
                return
            }
            // Il pan marca una SELEZIONE secondo il modo (pennello/rettangolo/lazo).
            // In modo "tocco" il pan non fa nulla (si marca con i tap → semi).
            switch g.state {
            case .began:
                proiettaCentroidi(in: v)
                catturaNormaleRif(p, in: v)
                rettInizio = p
                lassoPunti = [p]
                if model.modoSelezione == .pennello {
                    model.applicaLazo([], aggiungi: model.selezioneAdditiva); pennella(p)
                }
            case .changed:
                switch model.modoSelezione {
                case .lazo:       lassoPunti.append(p); aggiornaTracciato(chiusa: true)
                case .rettangolo: aggiornaRettangolo(da: rettInizio ?? p, a: p)
                case .pennello:   pennella(p); disegnaCerchioPennello(p)
                case .tocco, .seleziona, .poligonale: break
                }
            case .ended, .cancelled:
                switch model.modoSelezione {
                case .lazo:
                    aggiornaTracciato(chiusa: true)
                    if lassoPunti.count >= 3 { selezionaDaPoligono(lassoPunti) }
                case .rettangolo:
                    if let a = rettInizio { selezionaDaRettangolo(a, p) }
                case .pennello, .tocco, .seleziona:
                    break
                case .poligonale:
                    break
                }
                lassoPunti = []; rettInizio = nil; cacheSchermo = []; lassoLayer?.path = nil
            default:
                break
            }
        }

        @MainActor func syncLazoPoligonale(in v: SCNView) {
            if model.modoSelezione != .poligonale || model.strumento != .box {
                if !lazoPoligonalePunti.isEmpty {
                    lazoPoligonalePunti = []
                    model.aggiornaLazoPoligonalePunti(0)
                    lassoLayer?.path = nil
                }
                lastLazoResetTick = model.lazoPoligonaleResetTick
                lastLazoApplyTick = model.lazoPoligonaleApplyTick
                return
            }
            if lastLazoResetTick != model.lazoPoligonaleResetTick {
                lastLazoResetTick = model.lazoPoligonaleResetTick
                lazoPoligonalePunti = []
                cacheSchermo = []
                lassoLayer?.path = nil
                model.aggiornaLazoPoligonalePunti(0)
            }
            if lastLazoApplyTick != model.lazoPoligonaleApplyTick {
                lastLazoApplyTick = model.lazoPoligonaleApplyTick
                if lazoPoligonalePunti.count >= 3 {
                    aggiornaTracciatoPoligonale(chiusa: true)
                    selezionaDaPoligono(lazoPoligonalePunti)
                }
            }
        }

        @MainActor private func aggiungiPuntoLazoPoligonale(_ p: CGPoint, in v: SCNView) {
            if lazoPoligonalePunti.isEmpty {
                proiettaCentroidi(in: v)
            }
            if lazoPoligonalePunti.count >= 3, let primo = lazoPoligonalePunti.first {
                let dx = p.x - primo.x, dy = p.y - primo.y
                if dx * dx + dy * dy < 18 * 18 {
                    aggiornaTracciatoPoligonale(chiusa: true)
                    selezionaDaPoligono(lazoPoligonalePunti)
                    return
                }
            }
            lazoPoligonalePunti.append(p)
            model.aggiornaLazoPoligonalePunti(lazoPoligonalePunti.count)
            aggiornaTracciatoPoligonale(chiusa: lazoPoligonalePunti.count >= 3)
            if lazoPoligonalePunti.count >= 3 {
                selezionaDaPoligono(lazoPoligonalePunti)
            }
        }

        private func aggiornaTracciatoPoligonale(chiusa: Bool) {
            guard !lazoPoligonalePunti.isEmpty else { lassoLayer?.path = nil; return }
            let path = UIBezierPath()
            path.move(to: lazoPoligonalePunti[0])
            for q in lazoPoligonalePunti.dropFirst() { path.addLine(to: q) }
            if chiusa { path.close() }
            for q in lazoPoligonalePunti {
                path.move(to: CGPoint(x: q.x + 5, y: q.y))
                path.addArc(withCenter: q, radius: 5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            }
            lassoLayer?.path = path.cgPath
        }

        @MainActor private func pennellaFacce(_ p: CGPoint) {
            let r2 = raggioPennello * raggioPennello
            var sel = Set<Int>()
            for (i, sp) in cacheSchermo {
                let dx = sp.x - p.x, dy = sp.y - p.y
                if dx * dx + dy * dy <= r2 && passaNormale(i) && visibile(i, sp) { sel.insert(i) }
            }
            if !sel.isEmpty { model.assegnaAFacciaAttiva(sel) }
        }

        @MainActor private func pennella(_ p: CGPoint) {
            let r2 = raggioPennello * raggioPennello
            var sel = Set<Int>()
            for (i, sp) in cacheSchermo {
                let dx = sp.x - p.x, dy = sp.y - p.y
                if dx * dx + dy * dy <= r2 && passaNormale(i) && visibile(i, sp) { sel.insert(i) }
            }
            if !sel.isEmpty { model.aggiungiAllaSelezione(sel) }
        }

        private func aggiornaRettangolo(da a: CGPoint, a b: CGPoint) {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
            lassoLayer?.path = UIBezierPath(rect: r).cgPath
        }

        @MainActor private func disegnaCerchioPennello(_ p: CGPoint) {
            let r = CGRect(x: p.x - raggioPennello, y: p.y - raggioPennello,
                           width: raggioPennello * 2, height: raggioPennello * 2)
            lassoLayer?.path = UIBezierPath(ovalIn: r).cgPath
        }

        // Trascinamento di una maniglia del box lungo il suo asse.
        private struct TrascinaBox {
            let faccia: FacciaBox
            let puntoAsse: SIMD3<Float>
            let asse: SIMD3<Float>
            let startParam: Float
            let startCoord: Float
        }
        private var trascinaBox: TrascinaBox?

        @MainActor private func handlePanBox(_ g: UIPanGestureRecognizer, in v: SCNView) {
            let p = g.location(in: v)
            switch g.state {
            case .began:
                let hits = v.hitTest(p, options: [
                    .searchMode: SCNHitTestSearchMode.all.rawValue,
                    .categoryBitMask: 1,
                ])
                cerca: for h in hits {
                    var n: SCNNode? = h.node
                    while let cur = n {   // risali da anello/nucleo al nodo "box:…"
                        if let f = model.facciaBox(perNome: cur.name) {
                            let c = model.centroFaccia(f)
                            let axis: SIMD3<Float> = {
                                switch f.asse {
                                case 0: return model.boxRot.columns.0
                                case 1: return model.boxRot.columns.1
                                default: return model.boxRot.columns.2
                                }
                            }()
                            if let s = parametroAsseDaTouch(p, puntoAsse: c, asse: axis, in: v) {
                                let coord = model.worldInLocaleBox(c)[f.asse]
                                trascinaBox = TrascinaBox(faccia: f,
                                                          puntoAsse: c,
                                                          asse: axis,
                                                          startParam: s,
                                                          startCoord: coord)
                            }
                            break cerca
                        }
                        n = cur.parent
                    }
                }
            case .changed:
                guard let tr = trascinaBox,
                      let s = parametroAsseDaTouch(p, puntoAsse: tr.puntoAsse, asse: tr.asse, in: v) else { return }
                model.aggiornaFacciaBox(tr.faccia, coord: tr.startCoord + (s - tr.startParam))
            case .ended, .cancelled:
                trascinaBox = nil
            default:
                break
            }
        }

        private func aggiornaTracciato(chiusa: Bool) {
            guard lassoPunti.count >= 2 else { lassoLayer?.path = nil; return }
            let path = UIBezierPath()
            path.move(to: lassoPunti[0])
            for q in lassoPunti.dropFirst() { path.addLine(to: q) }
            if chiusa { path.close() }
            lassoLayer?.path = path.cgPath
        }

        private func puntoInPoligono(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
            guard poly.count >= 3 else { return false }
            var dentro = false
            var j = poly.count - 1
            for i in 0..<poly.count {
                let a = poly[i], b = poly[j]
                if (a.y > p.y) != (b.y > p.y),
                   p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                    dentro.toggle()
                }
                j = i
            }
            return dentro
        }

        private func discendente(_ n: SCNNode, di root: SCNNode) -> Bool {
            var cur: SCNNode? = n
            while let c = cur { if c === root { return true }; cur = c.parent }
            return false
        }
    }
}

// MARK: – Strutture export proxy (§9)

private extension SIMD3 where Scalar == Float {
    var lista: [Float] { [x, y, z] }
}

private struct MeshInfoJSON: Codable { let vertici: Int; let triangoli: Int }
private struct PianoJSON: Codable { let punto: [Float]; let normale: [Float] }
private struct PianoBaseJSON: Codable {
    let origine: [Float]; let normale: [Float]; let right: [Float]; let up: [Float]
}
private struct FacciaOverrideJSON: Codable {
    let id: Int; let nome: String; let tipo: String; let colore: String
    let priorita: Int; let n_triangoli: Int; let triangoli: [Int]; let piano: PianoJSON?
}
private struct ProxyOverridesJSON: Codable {
    let versione: Int; let stato: String; let mesh: MeshInfoJSON
    let piano_base: PianoBaseJSON?; let facce: [FacciaOverrideJSON]
}
private struct PianoProxyJSON: Codable {
    let id: Int; let nome: String; let tipo: String; let priorita: Int
    let punto: [Float]; let normale: [Float]
}
private struct MultipianoJSON: Codable {
    let versione: Int; let stato: String
    let piano_base: PianoBaseJSON?; let piani: [PianoProxyJSON]
}

/// Payload dei piani caricato sul backend (out/planes.json) come input della
/// proiezione foto→piani. Rispetto a MultipianoJSON include per ogni piano i
/// `triangoli` (maschera/estensione sulla mesh pulita) e usa la chiave `planes`.
private struct PianoUploadJSON: Codable {
    let id: Int; let nome: String; let tipo: String; let priorita: Int
    let punto: [Float]; let normale: [Float]
    let corners: [[Float]]
    let n_triangoli: Int; let triangoli: [Int]
}
private struct PianiUploadDoc: Codable {
    let schema: String; let versione: Int; let stato: String
    let piano_base: PianoBaseJSON?; let planes: [PianoUploadJSON]
}

// MARK: – Modello: scena, camera, caricamento mesh

/// Strumento attivo nell'editor 3D.
/// Dati 2D per il pannello "rileva perimetro" (coordinate u,v nel piano di slice).
struct PerimetroDisegno {
    var segmenti: [(CGPoint, CGPoint)] = []
    var punti: [CGPoint] = []
    var angoli: [CGPoint] = []   // spigoli del profilo = bersagli di snap
    var anelli: [[CGPoint]] = []   // anelli già salvati ad altre quote (riferimento)
    var spline: [CGPoint] = []
    var bounds: CGRect = .zero
}

/// Pannello 2D top-down della sezione: mostra il bordo (ciano) e lo ricalca a
/// linea/spline (giallo). Tap = aggiunge un punto. Disaccoppiato dalla camera 3D
/// (la sezione di una facciata è una curva piana: niente "sparizione" di geometria).
/// Mini-wizard del profilo di rilievo: poche domande → imposta le tolleranze
/// (che restano modificabili sotto). Per-sessione.
private struct ProfiloRilievoSheet: View {
    @ObservedObject var model: Mesh3DModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipologia edificio") {
                    Picker("Tipologia", selection: $model.profTipologia) {
                        ForEach(TipologiaEdificio.allCases) { Text($0.etichetta).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("Imposta le tolleranze qui sotto. Cambiandole manualmente passi a “Custom”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Cosa tenere / ignorare") {
                    Toggle("Tieni sporgenze (torrette, bovindi)", isOn: bind(\.profTieniSporgenze))
                    Toggle("Ignora balconi e cornici", isOn: bind(\.profIgnoraBalconi))
                }
                Section("Tolleranze") {
                    sliderRow("Profondità min. sporgenza", value: bind(\.profProfonditaSporgenzaM),
                              range: 0.1...1.0, unit: "m")
                    sliderRow("Tolleranza muro complanare", value: bind(\.profTolMergeM),
                              range: 0.02...0.30, unit: "m")
                    VStack(alignment: .leading) {
                        HStack { Text("Sensibilità (più piani)"); Spacer()
                            Text(String(format: "%.0f%%", model.profSensibilita * 100)).foregroundStyle(.secondary) }
                        Slider(value: bind(\.profSensibilita), in: 0...1)
                    }
                }
                Section {
                    Button {
                        dismiss()
                        Task { await model.segmentaTuttoAutomatico() }
                    } label: {
                        Label("Applica e rileva", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Profilo di rilievo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fatto") { dismiss() } } }
        }
    }

    /// Binding che marca il profilo come Custom quando l'utente tocca una soglia.
    private func bind<T>(_ kp: ReferenceWritableKeyPath<Mesh3DModel, T>) -> Binding<T> {
        Binding(get: { model[keyPath: kp] },
                set: { model[keyPath: kp] = $0; if model.profTipologia != .custom { model.profTipologia = .custom } })
    }

    private func sliderRow(_ titolo: String, value: Binding<Float>, range: ClosedRange<Float>, unit: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(titolo); Spacer()
                Text(String(format: "%.2f %@", value.wrappedValue, unit)).foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }
}

private struct PannelloPerimetro: View {
    @ObservedObject var model: Mesh3DModel
    @State private var dito: CGPoint? = nil   // posizione corrente del dito (per la lente)
    @State private var preso: Int? = nil      // indice del punto in trascinamento
    @State private var iniziato = false       // primo onChanged del gesto già gestito

    var body: some View {
        GeometryReader { geo in
            let d = model.disegnoPerimetro
            let b = d.bounds
            let pad: CGFloat = 28
            let scala: CGFloat = (b.width > 0 && b.height > 0)
                ? min((geo.size.width - 2 * pad) / b.width, (geo.size.height - 2 * pad) / b.height)
                : 1
            let offX = (geo.size.width - b.width * scala) / 2
            let offY = (geo.size.height - b.height * scala) / 2
            let toView = { (p: CGPoint) -> CGPoint in
                CGPoint(x: offX + (p.x - b.minX) * scala, y: offY + (b.maxY - p.y) * scala)
            }
            let toUV = { (p: CGPoint) -> CGPoint in
                CGPoint(x: b.minX + (p.x - offX) / scala, y: b.maxY - (p.y - offY) / scala)
            }
            let scena = { (ctx: GraphicsContext) in
                var sp = Path()
                for s in d.segmenti { sp.move(to: toView(s.0)); sp.addLine(to: toView(s.1)) }
                ctx.stroke(sp, with: .color(.teal), lineWidth: 1.5)
                for s in d.segmenti {
                    let m = CGPoint(x: (s.0.x + s.1.x) / 2, y: (s.0.y + s.1.y) / 2)
                    let v = toView(m)
                    ctx.fill(Path(ellipseIn: CGRect(x: v.x - 1.5, y: v.y - 1.5, width: 3, height: 3)), with: .color(.teal))
                }
                // anelli già salvati ad altre quote (riferimento tenue)
                for anello in d.anelli where anello.count >= 2 {
                    var rp = Path(); rp.move(to: toView(anello[0]))
                    for q in anello.dropFirst() { rp.addLine(to: toView(q)) }
                    if model.chiudiPerimetro, anello.count >= 3 { rp.addLine(to: toView(anello[0])) }
                    ctx.stroke(rp, with: .color(.orange.opacity(0.5)), lineWidth: 1.5)
                    for q in anello { let v = toView(q)
                        ctx.fill(Path(ellipseIn: CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6)),
                                 with: .color(.orange.opacity(0.6))) }
                }
                // spigoli del profilo = bersagli di snap (cerchietti vuoti ciano)
                for a in d.angoli {
                    let v = toView(a)
                    ctx.stroke(Path(ellipseIn: CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)),
                               with: .color(.cyan.opacity(0.9)), lineWidth: 1.5)
                }
                if d.spline.count >= 2 {
                    var yp = Path(); yp.move(to: toView(d.spline[0]))
                    for q in d.spline.dropFirst() { yp.addLine(to: toView(q)) }
                    ctx.stroke(yp, with: .color(.yellow), lineWidth: 2.5)
                }
                for (i, q) in d.punti.enumerated() {
                    let v = toView(q)
                    let r: CGFloat = (i == preso) ? 7 : 5
                    ctx.fill(Path(ellipseIn: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(i == preso ? .orange : .yellow))
                }
            }
            ZStack {
                Color.black.opacity(0.9)
                Canvas { ctx, _ in scena(ctx) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        dito = val.location
                        guard b.width > 0 else { return }
                        let raggioUV = 22 / scala            // ~22 px in coordinate u,v
                        let snapUV = 16 / scala
                        if !iniziato {
                            iniziato = true
                            // se tocco vicino a un punto esistente → lo afferro per spostarlo
                            preso = model.indicePuntoPerimetro(vicinoUV: toUV(val.location), raggioUV: raggioUV)
                        }
                        if let i = preso {
                            model.muoviPuntoPerimetro(i, aUV: toUV(val.location), raggioSnapUV: snapUV)
                        }
                    }
                    .onEnded { val in
                        dito = nil
                        defer { preso = nil; iniziato = false }
                        guard b.width > 0 else { return }
                        let snapUV = 16 / scala
                        if let i = preso {
                            model.muoviPuntoPerimetro(i, aUV: toUV(val.location), raggioSnapUV: snapUV)
                        } else {
                            model.toccaUV(toUV(val.location), raggioSnapUV: snapUV)   // nuovo punto con snap
                        }
                    })
                // Lente d'ingrandimento sotto il dito
                if let p = dito {
                    let zoom: CGFloat = 2.6
                    let lato: CGFloat = 132
                    let cx = min(max(p.x, lato / 2), geo.size.width - lato / 2)
                    let cy = max(p.y - 110, lato / 2)   // sopra il dito
                    Canvas { ctx, _ in
                        ctx.translateBy(x: lato / 2 - p.x * zoom, y: lato / 2 - p.y * zoom)
                        ctx.scaleBy(x: zoom, y: zoom)
                        scena(ctx)
                    }
                    .frame(width: lato, height: lato)
                    .background(Color.black.opacity(0.92))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.5))
                    .overlay(Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(.yellow))
                    .position(x: cx, y: cy)
                    .allowsHitTesting(false)
                }
                if b.width == 0 {
                    Text("Nessuna sezione a questa quota — sposta lo slider")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                VStack {
                    HStack {
                        Text("Sezione dall'alto · ricalca il bordo")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.4), in: Capsule())
                        Spacer()
                    }.padding(12)
                    Spacer()
                }
            }
        }
    }
}

enum StrumentoMesh3D: String, CaseIterable, Identifiable {
    case orbita     // naviga (orbit/pan/zoom)
    case box        // box di lavoro + crop
    case seleziona  // lazo a mano libera per selezionare triangoli
    case facce      // pennelli colorati: assegna triangoli a facce/piani
    case assi       // due linee sulla mesh: verticale + orizzontale edificio
    case allinea    // seleziona vertici/spigoli/facce dei piani e allineali agli assi
    case punti      // piano livello-zero: 3+ punti sul muro → piano medio

    var id: String { rawValue }
    var icona: String {
        switch self {
        case .orbita:    return "hand.draw"
        case .box:       return "cube"
        case .seleziona: return "lasso"
        case .facce:     return "square.stack.3d.up"
        case .assi:      return "arrow.up.and.down.and.arrow.left.and.right"
        case .allinea:   return "arrow.up.left.and.arrow.down.right"
        case .punti:     return "square.3.layers.3d.top.filled"
        }
    }
    var etichetta: String {
        switch self {
        case .orbita:    return "Naviga"
        case .box:       return "Box"
        case .seleziona: return "Seleziona"
        case .facce:     return "Piani"
        case .assi:      return "Assi"
        case .allinea:   return "Allinea"
        case .punti:     return "Piano base"
        }
    }
}

/// Tipo di sub-elemento selezionabile sui piani proxy (per Allinea).
enum ElementoTipo: String, CaseIterable, Identifiable {
    case vertice, spigolo, faccia
    var id: String { rawValue }
    var etichetta: String {
        switch self { case .vertice: return "Vertici"; case .spigolo: return "Spigoli"; case .faccia: return "Facce" }
    }
    var icona: String {
        switch self { case .vertice: return "circle.grid.2x2"; case .spigolo: return "line.diagonal"; case .faccia: return "square.dashed" }
    }
}

/// Riferimento degli assi di allineamento.
enum AssiRiferimento: String, CaseIterable, Identifiable {
    case edificio, mondo
    var id: String { rawValue }
    var etichetta: String { self == .edificio ? "Edificio" : "Mondo" }
}

/// Identità di un sub-elemento: faccia + indice (vertice o spigolo).
struct ElemId: Hashable { let faccia: Int; let k: Int }

/// Tipologia di edificio: preimposta le tolleranze del rilievo (profilo).
enum TipologiaEdificio: String, CaseIterable, Identifiable {
    case storico, moderno, misto, custom
    var id: String { rawValue }
    var etichetta: String {
        switch self {
        case .storico: return "Storico"
        case .moderno: return "Moderno"
        case .misto:   return "Misto"
        case .custom:  return "Custom"
        }
    }
}

/// Preset per l'auto-proposta BCS: controlla quante facce architettoniche tenere.
enum AutoBCSPreset: String, CaseIterable, Identifiable {
    case pochi, standard, dettaglio
    var id: String { rawValue }
    var etichetta: String {
        switch self {
        case .pochi: return "BCS pochi"
        case .standard: return "BCS standard"
        case .dettaglio: return "BCS dettaglio"
        }
    }
}

/// Modo di selezione (§2): lazo libero, rettangolo, pennello.
enum ModoSelezione: String, CaseIterable, Identifiable {
    case seleziona, tocco, pennello, rettangolo, lazo, poligonale
    var id: String { rawValue }
    var etichetta: String {
        switch self {
        case .seleziona:  return "Seleziona"
        case .tocco:      return "Tocco"
        case .pennello:   return "Pennello"
        case .rettangolo: return "Rettangolo"
        case .lazo:       return "Lazo"
        case .poligonale: return "Lazo poly"
        }
    }
    var icona: String {
        switch self {
        case .seleziona:  return "hand.point.up.left"
        case .tocco:      return "hand.tap"
        case .pennello:   return "paintbrush.pointed"
        case .rettangolo: return "rectangle.dashed"
        case .lazo:       return "lasso"
        case .poligonale: return "skew"
        }
    }
    /// Modi che producono una selezione di triangoli col pan (vs tocco/seleziona).
    var disegnaSelezione: Bool { self == .pennello || self == .rettangolo || self == .lazo }
    var selezioneMesh: Bool { disegnaSelezione || self == .poligonale }
}

enum AsseMovimentoPoligono: String, CaseIterable, Identifiable {
    case libero, x, y, z
    var id: String { rawValue }
    var etichetta: String {
        switch self {
        case .libero: return "Libero"
        case .x: return "Asse X"
        case .y: return "Asse Y"
        case .z: return "Asse Z"
        }
    }
}

private struct ManigliaPoligonoAttiva {
    let faccia: Int
    let edge: Bool
    let indice: Int
}

private struct PuntoRevisionePiano {
    let punto: SIMD3<Float>
    let triangolo: Int
    let pianoId: Int
}

/// Faccia del box di lavoro trascinabile (una maniglia per lato).
enum FacciaBox: String {
    case xMin, xMax, yMin, yMax, zMin, zMax
    var asse: Int { (self == .xMin || self == .xMax) ? 0 : (self == .yMin || self == .yMax) ? 1 : 2 }
    var isMin: Bool { self == .xMin || self == .yMin || self == .zMin }
}

@MainActor
final class Mesh3DModel: ObservableObject {
    let nome: String
    let scene = SCNScene()
    let contentNode = SCNNode()   // contiene SOLO la mesh (editabile)
    private let selectionNode = SCNNode()  // overlay dei triangoli selezionati
    private let facceProxyNode = SCNNode()  // overlay colorato delle facce proxy
    private let markersNode = SCNNode()  // punti in corso (sfere + polilinea), world space
    private let lineNode = SCNNode()     // polilinea della faccia in costruzione
    private let pianoBaseNode = SCNNode() // quad del piano livello-zero (§4)
    private let pianiNode = SCNNode()     // quad dei piani proxy fittati (§6)
    private let semiNode = SCNNode()      // puntini-seme del flusso rapido "Tocca semi"
    private let perimetroNode = SCNNode() // slice orizzontale + traccia del perimetro
    private let assiManualiNode = SCNNode() // linee manuali per il frame editor
    private let cursoreNode = SCNNode()   // mirino 3D d'ispezione
    private let revisionePianiNode = SCNNode() // riferimenti utente per il rifit dei piani
    private let pianiTexturizzatiNode = SCNNode()
    private let sviluppoPianiNode = SCNNode()

    @Published var numVertici = 0
    @Published var numTriangoli = 0
    @Published var caricamento = false
    @Published var errore: String?
    /// Incrementato per chiedere alla vista una re-inquadratura (frameNodes).
    @Published var reframeTick = 0
    @Published private(set) var haPianiTexturizzati = false
    @Published var mostraSviluppoPiani = false {
        didSet { aggiornaModalitaPianiTexturizzati() }
    }

    var nodoDaInquadrare: SCNNode {
        mostraSviluppoPiani && haPianiTexturizzati ? sviluppoPianiNode : contentNode
    }

    @Published var strumento: StrumentoMesh3D = .orbita {
        didSet {
            boxNode.isHidden = strumento != .box
            assiManualiNode.isHidden = strumento != .assi
            aggiornaClip()
        }
    }

    // Box di lavoro orientato (§1): origine + assi `boxRot` (NON ruota la mesh),
    // bounds `boxLo/boxHi` espressi nel frame locale del box.
    private let boxNode = SCNNode()
    private(set) var frameOrigin = SIMD3<Float>(repeating: 0)
    private(set) var boxRot = matrix_identity_float3x3
    private(set) var boxLo = SIMD3<Float>(repeating: -1)
    private(set) var boxHi = SIMD3<Float>(repeating: 1)

    // Selezione + taglio (T1)
    private(set) var mesh = EditableMesh(vertices: [], triangles: [])
    /// Cambia a ogni modifica distruttiva locale. Impedisce a un rilevamento
    /// backend avviato prima del taglio di sovrascrivere i piani aggiornati.
    @Published private(set) var meshRevision = 0
    /// Cambia per ogni modifica persistente a mesh o piani. La vista lo usa per
    /// accodare un unico autosave dopo una sequenza ravvicinata di operazioni.
    @Published private(set) var workspaceRevision = 0
    /// Mesh come caricata (prima di crop/pulizia): per "riparti da zero".
    private var meshOriginale: EditableMesh?
    /// Adiacenza saldata in cache (ricostruita pigramente): velocizza ogni crescita.
    private var adiacenzaCache: EditableMesh.Adiacenza?
    func adiacenza() -> EditableMesh.Adiacenza {
        if let a = adiacenzaCache { return a }
        let a = mesh.costruisciAdiacenza(); adiacenzaCache = a; return a
    }
    private(set) var selezione = Set<Int>()
    @Published var numSelezionati = 0
    @Published var modoSelezione: ModoSelezione = .seleziona
    @Published var visteOrtografiche = true
    /// Le nuove selezioni si sommano invece di sostituire (più zone insieme).
    @Published var selezioneAdditiva = false
    @Published private(set) var numPuntiLazoPoligonale = 0
    private(set) var lazoPoligonaleResetTick = 0
    private(set) var lazoPoligonaleApplyTick = 0
    @Published private(set) var numPuntiAssiManuali = 0
    private(set) var puntiAssiManuali: [SIMD3<Float>] = []
    private var anteprimaAssiManuali: (a: SIMD3<Float>, b: SIMD3<Float>)?
    private var assiManualiFissati = false
    var testoPassoAssiManuali: String {
        switch numPuntiAssiManuali {
        case 0: return "tocca in basso della verticale"
        case 1: return "tocca in alto della verticale"
        case 2: return "tocca il primo punto orizzontale"
        case 3: return "tocca il secondo punto orizzontale"
        default: return assiManualiFissati ? "assi manuali attivi" : "assi pronti"
        }
    }
    /// Flusso rapido: ogni tocco lascia un seme; "Cresci tutti" li fa crescere insieme.
    @Published var modoSemi = false
    @Published private(set) var numSemi = 0
    private var semiTocco: [(tri: Int, punto: SIMD3<Float>)] = []
    // Rileva perimetro: slice orizzontale + tracciamento del perimetro a punti.
    @Published var modoPerimetro = false
    @Published var perimetroTraccia = false   // false = posiziona sezione su 3D; true = traccia 2D
    @Published var chiudiPerimetro = false { didSet { aggiornaSlice() } }   // chiusura opzionale (default aperto)
    @Published var quotaSlice: Float = 0.5 { didSet { aggiornaSlice() } }
    /// Sensibilità del rilevamento angoli (0 = solo gli spigoli principali,
    /// 1 = anche i piccoli risvolti). Pilota eps semplificazione + lunghezza min muro.
    @Published var sensibilitaAngoli: Float = 0.5 { didSet { if modoPerimetro { aggiornaSlice() } } }
    /// Snap dei punti agli spigoli del profilo (disattivabile).
    @Published var snapPerimetroAttivo = true
    @Published private(set) var numPuntiPerimetro = 0
    @Published private(set) var numAnelliPerimetro = 0
    private var puntiPerimetro: [SIMD3<Float>] = []
    private var anelliPerimetro: [[SIMD3<Float>]] = []   // anelli salvati a quote diverse
    private var ultimaSezione: [(SIMD3<Float>, SIMD3<Float>)] = []   // segmenti per l'auto-angoli
    private var angoliSlice: [SIMD3<Float>] = []   // spigoli del profilo (bersagli di snap)
    private var sliceS0: Float = 0   // quota assoluta del piano di slice (lungo su)
    private var prevMostraMesh = true   // ripristino visibilità mesh uscendo dal perimetro
    private var perimE1 = SIMD3<Float>(1, 0, 0)   // base orizzontale 2D del piano di slice
    private var perimE2 = SIMD3<Float>(0, 0, 1)
    /// Dati per il pannello 2D del perimetro (coordinate u,v nel piano orizzontale).
    @Published private(set) var disegnoPerimetro = PerimetroDisegno()
    // Pennello: dimensione + vincolo alle normali della geometria
    @Published var raggioPennello: CGFloat = 42
    @Published var vincolaNormali = false
    @Published var tolleranzaNormaleGradi: Double = 30

    // Facce proxy (§3): pennelli colorati = facce/piani
    @Published var facce: [FacciaProxy] = []
    @Published var facciaAttivaId: Int?
    /// Insieme dei piani su cui mostrare le maniglie: i selezionati + l'attivo.
    var facceAttiveSet: Set<Int> {
        var s = facceSelezionate
        if let a = facciaAttivaId { s.insert(a) }
        return s
    }
    /// Multi-selezione: insieme dei piani selezionati (oltre a quello attivo).
    @Published var facceSelezionate: Set<Int> = []
    @Published var multiSelezione = false
    // MARK: Allinea — selezione sub-elementi dei piani + assi
    @Published var tipoElemento: ElementoTipo = .vertice
    @Published var rifAssiAllinea: AssiRiferimento = .edificio
    @Published var allineaAsse0 = false   // r (edificio) / X (mondo)
    @Published var allineaAsse1 = true    // u (edificio) / Y (mondo) — verticale di default
    @Published var allineaAsse2 = false   // n (edificio) / Z (mondo)
    @Published var attendoSorgenteAllinea = false
    @Published var spostaAllinea = false   // drag = sposta la selezione (invece di selezionare a rettangolo)
    @Published private(set) var numElementiSel = 0
    // MARK: Profilo di rilievo — vincoli/tolleranze per Auto piani (per-sessione)
    @Published var profTipologia: TipologiaEdificio = .storico { didSet { applicaPresetProfilo() } }
    @Published var profTieniSporgenze = true     // torrette/bovindi a qualsiasi quota
    @Published var profIgnoraBalconi = true      // scarta solette/aggetti orizzontali locali
    @Published var profTolMergeM: Float = 0.08   // m: offset max per fondere muri complanari
    @Published var profProfonditaSporgenzaM: Float = 0.30  // m: oltre = sporgenza strutturale separata
    @Published var profSensibilita: Float = 0.5  // 0..1: più alto = tieni anche piani piccoli
    @Published var mostraProfilo = false         // sheet del wizard
    @Published var autoBCSPreset: AutoBCSPreset = .standard
    @Published var bcsBinMetri: Float = 0.10
    @Published var bcsAngTolGradi: Float = 15
    @Published var bcsMinAreaFacciata: Float = 2.0
    @Published var bcsMinAreaSpalletta: Float = 0.7
    @Published var bcsMaxFacciate: Int = 7
    @Published var bcsMaxSpallette: Int = 10

    /// Soglia area "facciata principale" (frazione dell'area massima), dal profilo.
    var sogliaAreaPrincipale: Float { 0.28 - 0.18 * profSensibilita }   // 0.28 → 0.10
    /// Soglia altezza "facciata principale" (frazione altezza edificio), dal profilo.
    var sogliaAltezzaPrincipale: Float { 0.30 - 0.18 * profSensibilita } // 0.30 → 0.12

    /// Applica i default di tolleranza in base alla tipologia (non tocca Custom).
    func applicaPresetProfilo() {
        switch profTipologia {
        case .storico:
            profTieniSporgenze = true; profIgnoraBalconi = true
            profTolMergeM = 0.08; profProfonditaSporgenzaM = 0.30; profSensibilita = 0.55
        case .moderno:
            profTieniSporgenze = true; profIgnoraBalconi = true
            profTolMergeM = 0.05; profProfonditaSporgenzaM = 0.25; profSensibilita = 0.45
        case .misto:
            profTieniSporgenze = true; profIgnoraBalconi = true
            profTolMergeM = 0.07; profProfonditaSporgenzaM = 0.28; profSensibilita = 0.50
        case .custom:
            break   // lascia i valori correnti
        }
    }

    func applicaPresetAutoBCS(_ preset: AutoBCSPreset) {
        autoBCSPreset = preset
        switch preset {
        case .pochi:
            bcsBinMetri = 0.12
            bcsAngTolGradi = 13
            bcsMinAreaFacciata = 3.5
            bcsMinAreaSpalletta = 1.2
            bcsMaxFacciate = 5
            bcsMaxSpallette = 6
        case .standard:
            bcsBinMetri = 0.10
            bcsAngTolGradi = 15
            bcsMinAreaFacciata = 2.0
            bcsMinAreaSpalletta = 0.7
            bcsMaxFacciate = 7
            bcsMaxSpallette = 10
        case .dettaglio:
            bcsBinMetri = 0.08
            bcsAngTolGradi = 18
            bcsMinAreaFacciata = 1.0
            bcsMinAreaSpalletta = 0.35
            bcsMaxFacciate = 10
            bcsMaxSpallette = 16
        }
        cursoreInfo = "\(preset.etichetta): preset applicato"
    }
    private var selVertici: Set<ElemId> = []
    private var selSpigoli: Set<ElemId> = []   // k = indice vertice iniziale dello spigolo
    private var selFacceAllinea: Set<Int> = []
    @Published var asseMovimentoPoligono: AsseMovimentoPoligono = .libero
    private var manigliaPoligonoAttiva: ManigliaPoligonoAttiva?
    @Published var pianiGenerati = 0
    private var prossimoIdFaccia = 1

    // Cursore d'ispezione 3D
    @Published var cursoreInfo: String?

    // ViewCube / navigazione
    @Published var cameraQuat = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    @Published var autoRuota = false
    /// Impostato dal container: applica l'orientamento camera (dir, up).
    var richiediSnap: ((SIMD3<Float>, SIMD3<Float>) -> Void)?
    /// Impostato dal container: dolly della camera, utile anche sul simulatore iPad.
    var richiediZoom: ((Float) -> Void)?
    /// Impostato dal container: torna a prospettiva quando l'utente ruota.
    var richiediProspettiva: (() -> Void)?

    /// Assi dell'EDIFICIO per la navigazione (fronte facciata + gravità), così il
    /// cubo mostra i lati buoni invece di tagliare la facciata sugli assi mondo.
    private(set) var assiNav: (r: SIMD3<Float>, u: SIMD3<Float>, n: SIMD3<Float>) =
        (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))

    /// Stima gli assi edificio: up = gravità; normale facciata = direzione di MINOR
    /// spessore orizzontale (PCA 2D dei vertici); destra = larghezza facciata.
    func calcolaAssiNavigazione() {
        if assiManualiFissati { return }
        guard !mesh.vertices.isEmpty else { return }
        let suStimato = simd_normalize(gravitaSu)

        func assiRettangoloNelPiano(normale n0: SIMD3<Float>, triangoli: Set<Int>) -> (r: SIMD3<Float>, u: SIMD3<Float>)? {
            let n = simd_normalize(n0)
            var e1 = simd_cross(suStimato, n)
            if simd_length(e1) < 1e-4 { e1 = simd_cross(SIMD3<Float>(1, 0, 0), n) }
            if simd_length(e1) < 1e-4 { e1 = simd_cross(SIMD3<Float>(0, 0, 1), n) }
            guard simd_length(e1) > 1e-4 else { return nil }
            e1 = simd_normalize(e1)
            let e2 = simd_normalize(simd_cross(n, e1))

            var punti: [SIMD3<Float>] = []
            let maxPuntiFrame = 5_000
            if triangoli.isEmpty {
                if mesh.vertices.count > maxPuntiFrame {
                    punti.reserveCapacity(maxPuntiFrame)
                    let step = max(1, mesh.vertices.count / maxPuntiFrame)
                    var idx = 0
                    while idx < mesh.vertices.count && punti.count < maxPuntiFrame {
                        punti.append(mesh.vertices[idx])
                        idx += step
                    }
                } else {
                    punti = mesh.vertices
                }
            } else {
                let lista = Array(triangoli)
                let step = max(1, lista.count / max(1, maxPuntiFrame / 3))
                punti.reserveCapacity(min(maxPuntiFrame, lista.count * 3))
                for (idx, ti) in lista.enumerated() where idx % step == 0 {
                    guard mesh.triangles.indices.contains(ti) else { continue }
                    let t = mesh.triangles[ti]
                    punti.append(mesh.vertices[Int(t.x)])
                    punti.append(mesh.vertices[Int(t.y)])
                    punti.append(mesh.vertices[Int(t.z)])
                    if punti.count >= maxPuntiFrame { break }
                }
            }
            guard punti.count >= 3 else { return nil }

            let coords = punti.map { (Float(simd_dot($0, e1)), Float(simd_dot($0, e2))) }

            func quantile(_ values: [Float], _ q: Float) -> Float {
                guard !values.isEmpty else { return 0 }
                let sorted = values.sorted()
                let idx = min(sorted.count - 1, max(0, Int((Float(sorted.count - 1) * q).rounded())))
                return sorted[idx]
            }

            var bestAngle: Float = 0
            var bestScore = Float.greatestFiniteMagnitude
            let steps = 45
            for i in 0..<steps {
                let angle = -Float.pi / 2 + Float(i) * Float.pi / Float(steps)
                let ca = cos(angle), sa = sin(angle)
                var xs: [Float] = []; xs.reserveCapacity(coords.count)
                var ys: [Float] = []; ys.reserveCapacity(coords.count)
                for (x, y) in coords {
                    xs.append(x * ca + y * sa)
                    ys.append(-x * sa + y * ca)
                }
                let w = max(quantile(xs, 0.98) - quantile(xs, 0.02), 1e-6)
                let h = max(quantile(ys, 0.98) - quantile(ys, 0.02), 1e-6)
                let score = w * h
                if score < bestScore {
                    bestScore = score
                    bestAngle = angle
                }
            }

            let ca = cos(bestAngle), sa = sin(bestAngle)
            let a1 = simd_normalize(e1 * ca + e2 * sa)
            let a2 = simd_normalize(-e1 * sa + e2 * ca)
            var up = abs(simd_dot(a1, suStimato)) >= abs(simd_dot(a2, suStimato)) ? a1 : a2
            if simd_dot(up, suStimato) < 0 { up = -up }
            var right = simd_cross(up, n)
            guard simd_length(right) > 1e-4 else { return nil }
            right = simd_normalize(right)
            up = simd_normalize(simd_cross(n, right))
            if simd_dot(up, suStimato) < 0 { up = -up; right = -right }
            return (right, up)
        }

        func applica(normale n0: SIMD3<Float>, triangoli: Set<Int>) -> Bool {
            var n = n0 - simd_dot(n0, suStimato) * suStimato
            guard simd_length(n) > 1e-4 else { return false }
            n = simd_normalize(n)
            if let assi = assiRettangoloNelPiano(normale: n, triangoli: triangoli) {
                assiNav = (r: assi.r, u: assi.u, n: n)
                return true
            }
            var r = simd_cross(suStimato, n)
            guard simd_length(r) > 1e-4 else { return false }
            r = simd_normalize(r)
            let u = simd_normalize(simd_cross(n, r))
            assiNav = (r: r, u: u, n: n)
            return true
        }

        if let attiva = facciaAttivaId,
           let f = facce.first(where: { $0.id == attiva }),
           let n = f.pianoNormale,
           abs(simd_dot(simd_normalize(n), suStimato)) < 0.65,
           applica(normale: n, triangoli: f.triangoli) {
            return
        }
        let verticalePiuGrande = facce.compactMap { f -> (Float, SIMD3<Float>, Set<Int>)? in
            guard let n = f.pianoNormale else { return nil }
            let nn = simd_normalize(n)
            guard abs(simd_dot(nn, suStimato)) < 0.65 else { return nil }
            let area = areaPoligono(f) ?? mesh.areaTriangoli(f.triangoli)
            return (area, nn, f.triangoli)
        }.max { $0.0 < $1.0 }
        if let best = verticalePiuGrande, applica(normale: best.1, triangoli: best.2) { return }

        var e1 = simd_cross(suStimato, SIMD3<Float>(0, 0, 1))
        if simd_length(e1) < 1e-4 { e1 = simd_cross(suStimato, SIMD3<Float>(1, 0, 0)) }
        e1 = simd_normalize(e1); let e2 = simd_normalize(simd_cross(suStimato, e1))
        var mean = SIMD3<Double>(repeating: 0)
        for v in mesh.vertices { mean += SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) }
        mean /= Double(mesh.vertices.count)
        let c = SIMD3<Float>(Float(mean.x), Float(mean.y), Float(mean.z))
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for v in mesh.vertices {
            let d = v - c
            let x = Double(simd_dot(d, e1)), y = Double(simd_dot(d, e2))
            sxx += x * x; sxy += x * y; syy += y * y
        }
        let tr = sxx + syy, det = sxx * syy - sxy * sxy
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        let l1 = tr / 2 + disc                              // autovalore maggiore
        var mx = sxy, my = l1 - sxx                          // autovettore maggiore (larghezza)
        if abs(mx) + abs(my) < 1e-9 { mx = 1; my = 0 }
        let ml = (mx * mx + my * my).squareRoot()
        let major = simd_normalize(e1 * Float(mx / ml) + e2 * Float(my / ml))
        let nFronte = simd_normalize(simd_cross(suStimato, major))  // minor spessore = fronte
        let assi = assiRettangoloNelPiano(normale: nFronte, triangoli: [])
        assiNav = (r: assi?.r ?? major, u: assi?.u ?? suStimato, n: nFronte)
    }

    func ricalcolaAssiAutomatici() {
        assiManualiFissati = false
        puntiAssiManuali = []
        anteprimaAssiManuali = nil
        numPuntiAssiManuali = 0
        assiManualiNode.childNodes.forEach { $0.removeFromParentNode() }
        assiManualiNode.geometry = nil
        calcolaAssiNavigazione()
        allineaBoxAgliAssiNavigazione()
        cursoreInfo = "Assi automatici ripristinati"
    }

    func resetAssiManuali() {
        assiManualiFissati = false
        puntiAssiManuali = []
        anteprimaAssiManuali = nil
        numPuntiAssiManuali = 0
        assiManualiNode.childNodes.forEach { $0.removeFromParentNode() }
        assiManualiNode.geometry = nil
        if strumento == .assi { cursoreInfo = testoPassoAssiManuali }
    }

    func flipAssiFronte() {
        assiNav = (r: -assiNav.r, u: assiNav.u, n: -assiNav.n)
        if puntiAssiManuali.count >= 4 {
            puntiAssiManuali.swapAt(2, 3)
            ridisegnaAssiManuali()
        } else {
            assiManualiFissati = true
        }
        allineaBoxAgliAssiNavigazione()
        cursoreInfo = "Fronte assi invertito"
        snapVista(assiNav.n)
    }

    func aggiungiPuntoAssiManuali(_ punto: SCNVector3) {
        if puntiAssiManuali.count >= 4 {
            puntiAssiManuali = []
            anteprimaAssiManuali = nil
            assiManualiFissati = false
        }
        puntiAssiManuali.append(SIMD3<Float>(punto.x, punto.y, punto.z))
        numPuntiAssiManuali = puntiAssiManuali.count
        if puntiAssiManuali.count == 1 || puntiAssiManuali.count == 3 {
            let p = puntiAssiManuali.last!
            anteprimaAssiManuali = (p, p)
        } else {
            anteprimaAssiManuali = nil
        }
        ridisegnaAssiManuali()
        if puntiAssiManuali.count == 4 {
            applicaAssiManuali()
        } else {
            cursoreInfo = testoPassoAssiManuali
        }
    }

    func iniziaLineaAssiManuali(_ punto: SCNVector3) {
        if puntiAssiManuali.count >= 4 {
            puntiAssiManuali = []
            assiManualiFissati = false
        }
        let p = SIMD3<Float>(punto.x, punto.y, punto.z)
        anteprimaAssiManuali = (p, p)
        cursoreInfo = puntiAssiManuali.count < 2 ? "Traccia verticale" : "Traccia orizzontale"
        ridisegnaAssiManuali()
    }

    func aggiornaLineaAssiManuali(_ punto: SCNVector3) {
        guard let start = anteprimaAssiManuali?.a else { return }
        anteprimaAssiManuali = (start, SIMD3<Float>(punto.x, punto.y, punto.z))
        ridisegnaAssiManuali()
    }

    func iniziaLineaAssiDaUltimoPunto() {
        guard puntiAssiManuali.count == 1 || puntiAssiManuali.count == 3,
              let start = puntiAssiManuali.last else { return }
        anteprimaAssiManuali = (start, start)
        cursoreInfo = puntiAssiManuali.count == 1 ? "Traccia verticale" : "Traccia orizzontale"
        ridisegnaAssiManuali()
    }

    func aggiornaAnteprimaAssiManuali(_ punto: SCNVector3?) {
        guard strumento == .assi,
              puntiAssiManuali.count == 1 || puntiAssiManuali.count == 3,
              let start = puntiAssiManuali.last,
              let punto else { return }
        anteprimaAssiManuali = (start, SIMD3<Float>(punto.x, punto.y, punto.z))
        ridisegnaAssiManuali()
    }

    func confermaLineaAssiManuali(_ punto: SCNVector3) {
        guard let start = anteprimaAssiManuali?.a else { return }
        let end = SIMD3<Float>(punto.x, punto.y, punto.z)
        anteprimaAssiManuali = nil
        guard simd_length(end - start) > estensioneMesh * 0.005 else {
            cursoreInfo = "Linea troppo corta"
            ridisegnaAssiManuali()
            return
        }
        if puntiAssiManuali.count >= 4 { puntiAssiManuali = [] }
        if puntiAssiManuali.count == 0 || puntiAssiManuali.count == 2 {
            puntiAssiManuali.append(start)
            puntiAssiManuali.append(end)
        } else {
            puntiAssiManuali = [start, end]
        }
        numPuntiAssiManuali = puntiAssiManuali.count
        ridisegnaAssiManuali()
        if puntiAssiManuali.count == 4 {
            applicaAssiManuali()
        } else {
            cursoreInfo = "Ora traccia orizzontale"
        }
    }

    func annullaLineaAssiManuali() {
        anteprimaAssiManuali = nil
        ridisegnaAssiManuali()
        cursoreInfo = testoPassoAssiManuali
    }

    func muoviPuntoAssiManuali(indice: Int, punto: SCNVector3) {
        guard puntiAssiManuali.indices.contains(indice) else { return }
        puntiAssiManuali[indice] = SIMD3<Float>(punto.x, punto.y, punto.z)
        anteprimaAssiManuali = nil
        numPuntiAssiManuali = puntiAssiManuali.count
        ridisegnaAssiManuali()
        if puntiAssiManuali.count == 4 {
            applicaAssiManuali(snap: false)
            cursoreInfo = "Punto assi spostato"
        }
    }

    private func applicaAssiManuali(snap: Bool = true) {
        guard puntiAssiManuali.count == 4 else { return }
        var up = puntiAssiManuali[1] - puntiAssiManuali[0]
        guard simd_length(up) > 1e-4 else {
            cursoreInfo = "Linea verticale troppo corta"
            return
        }
        up = simd_normalize(up)

        var right = puntiAssiManuali[3] - puntiAssiManuali[2]
        right -= simd_dot(right, up) * up
        guard simd_length(right) > 1e-4 else {
            cursoreInfo = "Linea orizzontale parallela alla verticale"
            return
        }
        right = simd_normalize(right)

        let normal = simd_normalize(simd_cross(right, up))
        assiNav = (r: right, u: up, n: normal)
        gravitaSu = up
        assiManualiFissati = true
        anteprimaAssiManuali = nil
        allineaBoxAgliAssiNavigazione()
        cursoreInfo = "Assi manuali attivi"
        if snap { snapVista(normal) }
    }

    private func allineaBoxAgliAssiNavigazione() {
        guard !mesh.vertices.isEmpty else { return }
        let (loW, hiW) = mesh.aabb
        frameOrigin = (loW + hiW) / 2
        boxRot = simd_float3x3(assiNav.r, assiNav.u, assiNav.n)
        let rt = boxRot.transpose
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices {
            let l = rt * (v - frameOrigin)
            lo = simd_min(lo, l)
            hi = simd_max(hi, l)
        }
        let margine = (hi - lo) * 0.02
        boxLo = lo - margine
        boxHi = hi + margine
        ricostruisciBox()
    }

    private func ridisegnaAssiManuali() {
        assiManualiNode.childNodes.forEach { $0.removeFromParentNode() }
        let pts = puntiAssiManuali
        let colori: [UIColor] = [
            UIColor.systemGreen, UIColor.systemGreen,
            UIColor.systemRed, UIColor.systemRed
        ]
        let dotRadius = CGFloat(max(estensioneMesh * 0.0045, 0.0015))
        for (i, p) in pts.enumerated() {
            let s = SCNNode(geometry: SCNSphere(radius: dotRadius))
            s.geometry?.materials = [materialeAssi(colori[min(i, colori.count - 1)])]
            s.renderingOrder = 1200
            s.position = SCNVector3(p.x, p.y, p.z)
            assiManualiNode.addChildNode(s)
        }
        if pts.count >= 2 {
            aggiungiFrecciaAssi(da: pts[0], a: pts[1], colore: UIColor.systemGreen)
        }
        if pts.count >= 4 {
            aggiungiFrecciaAssi(da: pts[2], a: pts[3], colore: UIColor.systemRed)
        }
        if let preview = anteprimaAssiManuali {
            let colore = pts.count < 2 ? UIColor.systemGreen : UIColor.systemRed
            var end = preview.b
            if simd_length(end - preview.a) < estensioneMesh * 0.01 {
                let dir = pts.count < 2 ? assiNav.u : assiNav.r
                end = preview.a + simd_normalize(dir) * max(estensioneMesh * 0.16, 0.05)
            }
            aggiungiFrecciaAssi(da: preview.a, a: end, colore: colore)
        }
    }

    private func materialeAssi(_ colore: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.emission.contents = colore.withAlphaComponent(0.25)
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        return m
    }

    private func aggiungiFrecciaAssi(da a: SIMD3<Float>, a b: SIMD3<Float>, colore: UIColor) {
        let delta = b - a
        let len = simd_length(delta)
        guard len > 1e-5 else { return }
        let dir = delta / len
        let radius = CGFloat(max(estensioneMesh * 0.0018, 0.0008))
        let coneH = CGFloat(max(min(len * 0.18, estensioneMesh * 0.055), estensioneMesh * 0.018))
        let shaftLen = max(CGFloat(len) - coneH * 0.72, radius)
        let mat = materialeAssi(colore)

        let shaft = SCNNode(geometry: SCNCylinder(radius: radius, height: shaftLen))
        shaft.geometry?.materials = [mat]
        let shaftCenter = a + dir * Float(shaftLen * 0.5)
        shaft.position = SCNVector3(shaftCenter.x, shaftCenter.y, shaftCenter.z)
        shaft.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir)
        shaft.renderingOrder = 1100
        assiManualiNode.addChildNode(shaft)

        let head = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: radius * 3.2, height: coneH))
        head.geometry?.materials = [mat]
        let headCenter = b - dir * Float(coneH * 0.5)
        head.position = SCNVector3(headCenter.x, headCenter.y, headCenter.z)
        head.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir)
        head.renderingOrder = 1200
        assiManualiNode.addChildNode(head)
    }

    func quatFrameNavigazione() -> simd_quatf {
        return simd_quatf(simd_float3x3(assiNav.r, assiNav.u, assiNav.n))
    }

    /// Snap della vista lungo una direzione, inquadrando la mesh.
    func snapVista(_ dir: SIMD3<Float>) {
        let d = simd_normalize(dir)
        let up: SIMD3<Float> = abs(simd_dot(d, assiNav.u)) > 0.9 ? assiNav.r : assiNav.u
        richiediSnap?(d, up)
    }
    func snapFronte()   { calcolaAssiNavigazione(); snapVista(assiNav.n) }
    func snapRetro()    { calcolaAssiNavigazione(); snapVista(-assiNav.n) }
    func snapAlto()     { calcolaAssiNavigazione(); snapVista(assiNav.u) }
    func snapBasso()    { calcolaAssiNavigazione(); snapVista(-assiNav.u) }
    func snapDestra()   { calcolaAssiNavigazione(); snapVista(assiNav.r) }
    func snapSinistra() { calcolaAssiNavigazione(); snapVista(-assiNav.r) }
    func snapIso()      { calcolaAssiNavigazione(); snapVista(assiNav.n + assiNav.r * 0.7 + assiNav.u * 0.6) }
    func zoomVista(_ fattore: Float) { richiediZoom?(fattore) }
    func tornaProspettivaPerRotazione() { richiediProspettiva?() }

    /// Snap dal ViewCube: asse 0=right,1=up,2=normale(fronte), con segno.
    func snapAsse(_ idx: Int, _ segno: Float) {
        calcolaAssiNavigazione()
        let a = assiNav
        let d = idx == 0 ? a.r : (idx == 1 ? a.u : a.n)
        snapVista(d * segno)
    }

    /// Auto-rotazione (turntable) attorno al centro mesh; off → ripristina l'orientamento.
    func toggleAutoRuota() {
        autoRuota.toggle()
        if autoRuota {
            let (lo, hi) = mesh.aabb
            let c = (lo + hi) / 2
            contentNode.pivot = SCNMatrix4MakeTranslation(c.x, c.y, c.z)
            contentNode.position = SCNVector3(c.x, c.y, c.z)
            let axis = haPianoBase ? pianoBaseUp : assiNav.u
            let rot = SCNAction.rotate(by: .pi * 2, around: SCNVector3(axis.x, axis.y, axis.z), duration: 16)
            contentNode.runAction(.repeatForever(rot), forKey: "spin")
        } else {
            contentNode.removeAction(forKey: "spin")
            contentNode.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            contentNode.pivot = SCNMatrix4Identity
            contentNode.position = SCNVector3Zero
        }
    }

    // Validazione (§8)
    @Published var mostraProxy = true { didSet { aggiornaVista() } }
    @Published var vistaValidazione: VistaValidazione = .normale { didSet { aggiornaVista() } }
    @Published var mostraPiani = false { didSet { ridisegnaPiani() } }
    /// Mostra/nasconde la geometria OC grigia editabile.
    @Published var mostraMesh = true { didSet { aggiornaVista() } }
    /// Attiva la versione texturizzata OC (nodo originale tenuto nascosto).
    @Published var mostraTexturaOC = false { didSet { aggiornaVista() } }
    /// Nodo texturizzato OC originale (estratto al caricamento, normalmente nascosto).
    private var ocTextureNode: SCNNode?
    private struct OCTexturePart {
        let node: SCNNode
        let sources: [SCNGeometrySource]
        let materials: [SCNMaterial]
        let vertexCount: Int
        let triangles: [[SIMD3<UInt32>]]
        let centroids: [[SIMD3<Float>]]
    }
    private struct TextureGridKey: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }
    private var ocTextureParts: [OCTexturePart] = []
    /// Corrispondenza 1:1 fra i triangoli editabili correnti e quelli della
    /// geometria OC texturizzata. Disponibile quando l'editor nasce dalla raw.
    private var textureTriangleIds: [Int]?
    private var textureTriangleIdsOriginali: [Int]?
    var haTexturaOC: Bool { ocTextureNode != nil }
    @Published var puoUndo = false
    @Published var puoRedo = false
    private var undoStack: [(EditableMesh, Set<Int>, [FacciaProxy], [Int]?)] = []
    private var redoStack: [(EditableMesh, Set<Int>, [FacciaProxy], [Int]?)] = []
    private let maxUndo = 8

    // Creazione faccia per punti
    @Published var numPuntiFaccia = 0
    private var puntiFaccia: [SCNVector3] = []
    private var raggioMarker: CGFloat = 0.05   // dimensione sfere, scalata sulla mesh
    private var estensioneMesh: Float = 1      // lato maggiore della mesh
    /// Soglia di planarità "buona" per le facce (1% del lato mesh).
    var sogliaErrore: Float { estensioneMesh * 0.01 }
    /// Lato maggiore della mesh (per soglie geometriche esterne, es. occlusione).
    var estensioneLato: Float { estensioneMesh }
    /// (#15) Verso "su" stimato dalla mesh (media delle facce orizzontali). Default
    /// world-Y; va sostituibile col vettore gravità reale delle pose ARKit.
    private(set) var gravitaSu = SIMD3<Float>(0, 1, 0)

    // Piano livello-zero (§4)
    @Published var haPianoBase = false
    private(set) var pianoBaseOrigine = SIMD3<Float>(repeating: 0)
    private(set) var pianoBaseNormale = SIMD3<Float>(0, 0, 1)
    private(set) var pianoBaseRight = SIMD3<Float>(1, 0, 0)
    private(set) var pianoBaseUp = SIMD3<Float>(0, 1, 0)

    init(meshFile: URL?, textureFile: URL? = nil, nome: String) {
        self.nome = nome
        configuraScena()
        // Sorgente, in ordine: file passato (download backend) → mesh OC reale
        // precaricata nel bundle (facciata_demo.obj) → mesh procedurale.
        let file = meshFile
            ?? Bundle.main.url(forResource: "facciata_demo", withExtension: "obj")
        if let file {
            caricamento = true
            Task { await caricaFile(file, textureFile: textureFile) }
        } else {
            let demo = MeshFactory.demoMesh()
            meshOriginale = demo
            installaMesh(demo)
        }
    }

    /// Ricarica la mesh originale e azzera tutto (facce, selezione, crop, undo).
    func ricaricaDaCapo() {
        guard let orig = meshOriginale else { return }
        installaMesh(orig)
        meshRevision += 1
        workspaceRevision += 1
    }

    private func configuraScena() {
        scene.background.contents = UIColor(EditorTheme.bg)
        scene.rootNode.addChildNode(contentNode)
        contentNode.addChildNode(facceProxyNode)
        contentNode.addChildNode(selectionNode)
        boxNode.isHidden = true
        contentNode.addChildNode(boxNode)
        scene.rootNode.addChildNode(pianoBaseNode)
        contentNode.addChildNode(pianiNode)
        contentNode.addChildNode(semiNode)
        contentNode.addChildNode(perimetroNode)
        assiManualiNode.isHidden = true
        scene.rootNode.addChildNode(assiManualiNode)
        cursoreNode.isHidden = true
        contentNode.addChildNode(cursoreNode)
        markersNode.addChildNode(lineNode)
        scene.rootNode.addChildNode(markersNode)
        contentNode.addChildNode(revisionePianiNode)
        contentNode.addChildNode(pianiTexturizzatiNode)
        sviluppoPianiNode.isHidden = true
        contentNode.addChildNode(sviluppoPianiNode)

        // Key light direzionale + ambient soft: stacco di rilievo sulle
        // sporgenze. La camera la gestisce il defaultCameraController (orbit).
        let key = SCNNode()
        key.light = SCNLight(); key.light!.type = .directional
        key.light!.intensity = 700
        key.eulerAngles = SCNVector3(-0.6, 0.5, 0)
        scene.rootNode.addChildNode(key)

        let amb = SCNNode()
        amb.light = SCNLight(); amb.light!.type = .ambient
        amb.light!.intensity = 400
        scene.rootNode.addChildNode(amb)
    }

    private static let coloreMesh = UIColor(white: 0.66, alpha: 1)

    /// Installa la mesh editabile: render, statistiche, scala marker, frame.
    private func installaMesh(_ m: EditableMesh) {
        mesh = m
        textureTriangleIds = textureTriangleIdsOriginali.flatMap {
            $0.count == m.triangleCount ? $0 : nil
        }
        selezione = []
        facce = []; facciaAttivaId = nil; pianiGenerati = 0; mostraPiani = false
        annullaRevisionePiani()
        haPianoBase = false; renderPianoBase(); annullaFaccia(); nascondiCursore()
        resetAssiManuali()
        undoStack = []; redoStack = []
        puoUndo = false; puoRedo = false
        renderMesh()
        calcolaScala()
        calcolaAssiNavigazione()   // assi edificio per il ViewCube
        allineaBox()        // default: box allineato alla geometria (mesh storte)
        inquadra()
    }

    /// (Ri)costruisce la geometria SceneKit dalla mesh editabile + overlay selezione.
    private func renderMesh() {
        adiacenzaCache = nil   // la mesh è cambiata: invalida l'adiacenza in cache
        pianiTexturizzatiNode.childNodes.forEach { $0.removeFromParentNode() }
        sviluppoPianiNode.childNodes.forEach { $0.removeFromParentNode() }
        haPianiTexturizzati = false
        mostraSviluppoPiani = false
        contentNode.geometry = mesh.scnGeometry(colore: Self.coloreMesh)
        numVertici = mesh.vertexCount
        numTriangoli = mesh.triangleCount
        ridisegnaSelezione()
        aggiornaVista()   // riapplica trasparenza mesh + overlay facce
        aggiornaClip()    // ri-applica il clip box (materiale ricreato)
        sincronizzaTextureConMesh()
    }

    private func ridisegnaSelezione() {
        selectionNode.geometry = mesh.selezioneGeometry(
            selezione, colore: UIColor(EditorTheme.accento).withAlphaComponent(0.55))
        numSelezionati = selezione.count
    }

    /// Scala i marker dei punti in base all'estensione della mesh (le coordinate
    /// OC sono arbitrarie: una sfera fissa sarebbe invisibile o gigante).
    private func calcolaScala() {
        let (lo, hi) = mesh.aabb   // bbox reale della mesh (flattenedClone dava 0 → maniglie/fit rotti)
        let d = hi - lo
        let ext = max(d.x, max(d.y, d.z))
        estensioneMesh = ext > 1e-5 ? ext : 1
        raggioMarker = CGFloat(max(ext * 0.012, 0.001))
        // Mirino: sfera arancione + croce bianca, sempre sopra la mesh.
        let sfera = SCNSphere(radius: CGFloat(ext * 0.008))
        let ms = SCNMaterial(); ms.diffuse.contents = UIColor(EditorTheme.accento)
        ms.lightingModel = .constant; ms.readsFromDepthBuffer = false
        sfera.materials = [ms]
        cursoreNode.geometry = sfera
        cursoreNode.childNodes.forEach { $0.removeFromParentNode() }
        cursoreNode.addChildNode(SCNNode(geometry: MeshFactory.croce3D(ext * 0.05, colore: .white)))
    }

    /// Posiziona il mirino sul punto toccato e dice su che faccia si trova.
    func posizionaCursore(_ punto: SCNVector3, triangolo: Int) {
        cursoreNode.position = punto
        cursoreNode.isHidden = false
        if let f = facce.first(where: { $0.triangoli.contains(triangolo) }) {
            cursoreInfo = "\(f.nome) · \(f.tipo.etichetta) · \(f.triangoli.count) tri"
        } else if facce.isEmpty {
            cursoreInfo = "nessuna faccia marcata"
        } else {
            cursoreInfo = "fuori dalle facce"
        }
    }

    func nascondiCursore() {
        cursoreNode.isHidden = true
        cursoreInfo = nil
    }

    private func caricaFile(_ url: URL, textureFile: URL? = nil) async {
        cursoreInfo = "Carico mesh…"
        let ext = url.pathExtension.lowercased()
        if ext == "obj" {
            let parsed = await Task.detached(priority: .userInitiated) {
                Self.caricaOBJEditabile(url)
            }.value
            if let em = parsed {
                meshOriginale = em
                installaMesh(em)
                let textureCaricata = textureFile.map(caricaTextureOC) ?? false
                caricamento = false
                if textureFile == nil || textureCaricata { cursoreInfo = nil }
                return
            }
            errore = "OBJ senza triangoli leggibili"
            caricamento = false
            return
        }
        do {
            // SceneKit/ModelIO caricano OBJ, USDZ, PLY, SCN, DAE da file.
            let loaded = try SCNScene(url: url, options: nil)
            let radice = SCNNode()
            for child in loaded.rootNode.childNodes { radice.addChildNode(child) }
            // Attacca temporaneamente per avere i worldTransform corretti, poi
            // estrai i buffer editabili e sostituisci con la geometria unica.
            contentNode.addChildNode(radice)
            if let em = EditableMesh.from(node: radice) {
                // Conserva il nodo texturizzato OC (nascosto + non selezionabile)
                // per il toggle "Texture OC", invece di scartarlo.
                radice.isHidden = true
                radice.enumerateHierarchy { n, _ in n.categoryBitMask = 2 }
                ocTextureNode = radice
                meshOriginale = em
                installaMesh(em)
                // La raw USDZ e' contemporaneamente geometria editabile e
                // livello texturizzato. Registra materiali e triangoli dopo
                // l'installazione, cosi' il Box la clippa durante il drag e il
                // crop definitivo elimina anche le porzioni della texture OC.
                registraPartiTexture(radice, associaDirettamente: true)
                aggiornaClip()
                mostraTexturaOC = true
            } else {
                errore = "Mesh senza triangoli leggibili"
            }
        } catch {
            errore = "Mesh non caricabile: \(error.localizedDescription)"
        }
        caricamento = false
        if errore == nil { cursoreInfo = nil }
    }

    /// Carica la mesh raw texturizzata come livello visivo, mantenendo la mesh
    /// clean separata come geometria editabile e sorgente del riconoscimento.
    @discardableResult
    private func caricaTextureOC(_ url: URL) -> Bool {
        do {
            let loaded = try SCNScene(url: url, options: nil)
            let radice = SCNNode()
            for child in loaded.rootNode.childNodes { radice.addChildNode(child) }

            // SceneKit lascia spesso `map_Kd` come semplice nome file. Per gli
            // OBJ assegna esplicitamente l'immagine adiacente al materiale.
            let textureImage: UIImage? = {
                guard url.pathExtension.lowercased() == "obj",
                      let files = try? FileManager.default.contentsOfDirectory(
                        at: url.deletingLastPathComponent(),
                        includingPropertiesForKeys: nil)
                else { return nil }
                let imageURL = files.first { file in
                    ["png", "jpg", "jpeg"].contains(file.pathExtension.lowercased())
                }
                return imageURL.flatMap { UIImage(contentsOfFile: $0.path) }
            }()

            var haGeometria = false
            var haMateriale = false
            radice.enumerateHierarchy { node, _ in
                // Categoria 2: visibile dalla camera, esclusa dagli hit-test
                // dell'editor che lavorano sulla categoria 1.
                node.categoryBitMask = 2
                guard let geometry = node.geometry else { return }
                haGeometria = true
                for material in geometry.materials {
                    if let textureImage {
                        material.diffuse.contents = textureImage
                        material.lightingModel = .constant
                    }
                    material.transparency = 1
                    if material.diffuse.contents != nil { haMateriale = true }
                }
            }
            guard haGeometria else {
                cursoreInfo = "Texture OC senza geometria"
                return false
            }
            guard url.pathExtension.lowercased() != "obj" || textureImage != nil else {
                cursoreInfo = "Immagine della texture OC mancante"
                return false
            }
            guard haMateriale else {
                cursoreInfo = "Materiale della texture OC mancante"
                return false
            }
            radice.isHidden = true
            contentNode.addChildNode(radice)
            ocTextureNode = radice
            registraPartiTexture(radice, associaDirettamente: true)
            sincronizzaTextureConMesh()
            mostraTexturaOC = true
            return true
        } catch {
            cursoreInfo = "Texture OC non caricabile: \(error.localizedDescription)"
            return false
        }
    }

    /// Installa il bundle OBJ/MTL/PNG prodotto dal baker cloud nello stesso frame
    /// della mesh OC. Il poligono dei piani resta invariato: cambiano solo UV e materiali.
    func caricaPianiTexturizzati(_ url: URL) throws {
        let loaded = try SCNScene(url: url, options: nil)
        let directory = url.deletingLastPathComponent()
        var textureCount = 0
        pianiTexturizzatiNode.childNodes.forEach { $0.removeFromParentNode() }
        for child in loaded.rootNode.childNodes {
            child.enumerateHierarchy { node, _ in
                node.categoryBitMask = 2
                guard let geometry = node.geometry else { return }
                let materials = geometry.materials.map { imported -> SCNMaterial in
                    // I materiali creati dall'importer OBJ possono conservare la
                    // texture MTL nella pipeline interna anche dopo aver cambiato
                    // diffuse.contents. Un materiale nuovo forza l'upload della PNG.
                    let material = SCNMaterial()
                    material.name = imported.name
                    let textureName = (imported.diffuse.contents as? String)
                        .map { URL(fileURLWithPath: $0).lastPathComponent }
                        ?? imported.name.map { "\($0).png" }
                    if let textureName {
                        let imageURL = directory.appendingPathComponent(textureName)
                        if let image = UIImage(contentsOfFile: imageURL.path) {
                            material.diffuse.contents = image
                            textureCount += 1
                        }
                    }
                    material.lightingModel = .constant
                    material.isDoubleSided = true
                    return material
                }
                geometry.materials = materials
            }
            pianiTexturizzatiNode.addChildNode(child)
        }
        guard textureCount > 0 else {
            pianiTexturizzatiNode.childNodes.forEach { $0.removeFromParentNode() }
            throw NSError(
                domain: "AcrobaticaProjection", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "PNG delle texture non leggibili"])
        }
        haPianiTexturizzati = !pianiTexturizzatiNode.childNodes.isEmpty
        // I piani coincidono quasi con la superficie OC: se la mesh resta opaca
        // davanti, l'utente vede il modello bianco invece delle ortofoto.
        mostraTexturaOC = false
        mostraMesh = false
        mostraPiani = false
        mostraProxy = false
        mostraSviluppoPiani = false
        cursoreInfo = "Piani texturizzati caricati"
    }

    /// Porta i piani texturizzati su XY conservando misure, poligoni e UV.
    /// L'ordine `plane_N` del bundle segue il perimetro saldato del detector.
    private func costruisciSviluppoPiani(objURL: URL) {
        struct VerticeOBJ: Hashable {
            let posizione: Int
            let texture: Int
        }
        struct GruppoOBJ {
            var nome = ""
            var materiale = ""
            var riferimenti: [VerticeOBJ] = []
        }
        struct Piano {
            let indice: Int
            let materiale: String
            let punti: [SIMD3<Float>]
            let uv: [SIMD2<Float>]
            let indici: [Int32]
            var orizzontale: SIMD3<Float>
            let verticale: SIMD3<Float>
            var minX: Float
            var maxX: Float
            let minY: Float
            let maxY: Float
        }

        sviluppoPianiNode.childNodes.forEach { $0.removeFromParentNode() }
        sviluppoPianiNode.simdPosition = .zero
        guard let text = try? String(contentsOf: objURL, encoding: .utf8) else { return }

        var positions: [SIMD3<Float>] = []
        var textureCoordinates: [SIMD2<Float>] = []
        var groups: [GruppoOBJ] = []
        var current = GruppoOBJ()
        func appendCurrent() {
            if !current.riferimenti.isEmpty { groups.append(current) }
        }
        func objIndex(_ raw: Int, count: Int) -> Int {
            raw > 0 ? raw - 1 : count + raw
        }
        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let parts = rawLine.split(whereSeparator: \Character.isWhitespace)
            guard let command = parts.first else { continue }
            switch command {
            case "v" where parts.count >= 4:
                if let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                    positions.append(SIMD3(x, y, z))
                }
            case "vt" where parts.count >= 3:
                if let u = Float(parts[1]), let v = Float(parts[2]) {
                    textureCoordinates.append(SIMD2(u, v))
                }
            case "o" where parts.count >= 2:
                appendCurrent()
                current = GruppoOBJ(nome: String(parts[1]))
            case "usemtl" where parts.count >= 2:
                current.materiale = String(parts[1])
            case "f" where parts.count >= 4:
                for token in parts.dropFirst() {
                    let refs = token.split(separator: "/", omittingEmptySubsequences: false)
                    guard refs.count >= 2, let vi = Int(refs[0]), let ti = Int(refs[1]) else {
                        continue
                    }
                    current.riferimenti.append(VerticeOBJ(
                        posizione: objIndex(vi, count: positions.count),
                        texture: objIndex(ti, count: textureCoordinates.count)))
                }
            default:
                continue
            }
        }
        appendCurrent()

        let up = simd_normalize(assiNav.u)
        var piani: [Piano] = []

        for group in groups {
            var localMap: [VerticeOBJ: Int32] = [:]
            var points: [SIMD3<Float>] = []
            var uv: [SIMD2<Float>] = []
            var indices: [Int32] = []
            for reference in group.riferimenti {
                guard positions.indices.contains(reference.posizione),
                      textureCoordinates.indices.contains(reference.texture) else { continue }
                if let index = localMap[reference] {
                    indices.append(index)
                } else {
                    let index = Int32(points.count)
                    localMap[reference] = index
                    points.append(positions[reference.posizione])
                    uv.append(textureCoordinates[reference.texture])
                    indices.append(index)
                }
            }
            guard points.count >= 3, indices.count >= 3 else { continue }
            let a = points[Int(indices[0])]
            let b = points[Int(indices[1])]
            let c = points[Int(indices[2])]
            var normal = simd_cross(b - a, c - a)
            guard simd_length(normal) > 1e-6 else { continue }
            normal = simd_normalize(normal)

            var vertical = up - normal * simd_dot(up, normal)
            if simd_length(vertical) < 0.2 {
                vertical = b - a
            }
            guard simd_length(vertical) > 1e-6 else { continue }
            vertical = simd_normalize(vertical)
            var horizontal = simd_cross(normal, vertical)
            guard simd_length(horizontal) > 1e-6 else { continue }
            horizontal = simd_normalize(horizontal)

            if uv.count == points.count {
                let meanU = uv.reduce(Float(0)) { $0 + $1.x } / Float(uv.count)
                let meanX = points.reduce(Float(0)) {
                    $0 + simd_dot($1, horizontal)
                } / Float(points.count)
                let covariance = zip(points, uv).reduce(Float(0)) { partial, pair in
                    partial + (simd_dot(pair.0, horizontal) - meanX) * (pair.1.x - meanU)
                }
                if covariance < 0 { horizontal = -horizontal }
            }

            let xs = points.map { simd_dot($0, horizontal) }
            let ys = points.map { simd_dot($0, vertical) }
            let identifier = group.nome.isEmpty ? group.materiale : group.nome
            let components = identifier.split(separator: "_")
            let index = components.count > 1 ? Int(components[1]) ?? Int.max : Int.max
            piani.append(Piano(
                indice: index, materiale: group.materiale, punti: points,
                uv: uv, indici: indices,
                orizzontale: horizontal, verticale: vertical,
                minX: xs.min() ?? 0, maxX: xs.max() ?? 0,
                minY: ys.min() ?? 0, maxY: ys.max() ?? 0))
        }
        piani.sort { $0.indice < $1.indice }
        guard !piani.isEmpty else { return }

        // Se due piani consecutivi condividono uno spigolo, scegli il verso che
        // porta lo spigolo comune a destra del precedente e a sinistra del nuovo.
        for index in 1..<piani.count {
            let previous = piani[index - 1]
            let current = piani[index]
            let prevRight = Self.centroBordo(
                previous.punti, asse: previous.orizzontale,
                estremoMassimo: true)
            let directLeft = Self.centroBordo(
                current.punti, asse: current.orizzontale,
                estremoMassimo: false)
            let flippedLeft = Self.centroBordo(
                current.punti, asse: current.orizzontale,
                estremoMassimo: true)
            if simd_distance(prevRight, flippedLeft) + 1e-4
                < simd_distance(prevRight, directLeft) {
                piani[index].orizzontale = -current.orizzontale
                piani[index].minX = -current.maxX
                piani[index].maxX = -current.minX
            }
        }

        var cursorX: Float = 0
        var globalMinY = Float.greatestFiniteMagnitude
        var globalMaxY = -Float.greatestFiniteMagnitude
        for plane in piani {
            globalMinY = min(globalMinY, plane.minY)
            globalMaxY = max(globalMaxY, plane.maxY)
        }

        for plane in piani {
            let developed = plane.punti.map { point -> SCNVector3 in
                let x = cursorX + simd_dot(point, plane.orizzontale) - plane.minX
                let y = simd_dot(point, plane.verticale) - globalMinY
                return SCNVector3(x, y, 0)
            }
            let vertexSource = SCNGeometrySource(vertices: developed)
            let textureSource = SCNGeometrySource(textureCoordinates: plane.uv.map {
                CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))
            })
            let element = SCNGeometryElement(
                indices: plane.indici, primitiveType: .triangles)
            let geometry = SCNGeometry(
                sources: [vertexSource, textureSource], elements: [element])
            let material = SCNMaterial()
            material.name = plane.materiale
            let imageURL = objURL.deletingLastPathComponent()
                .appendingPathComponent("\(plane.materiale).png")
            material.diffuse.contents = UIImage(contentsOfFile: imageURL.path)
            material.lightingModel = .constant
            material.isDoubleSided = true
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.name = "sviluppo:\(plane.indice)"
            node.categoryBitMask = 2
            sviluppoPianiNode.addChildNode(node)
            cursorX += max(plane.maxX - plane.minX, 0)
        }
        sviluppoPianiNode.simdPosition = SIMD3(-cursorX * 0.5,
                                                -(globalMaxY - globalMinY) * 0.5,
                                                0)
    }

    private static func centroBordo(
        _ points: [SIMD3<Float>], asse: SIMD3<Float>, estremoMassimo: Bool
    ) -> SIMD3<Float> {
        let values = points.map { simd_dot($0, asse) }
        guard let lo = values.min(), let hi = values.max() else { return .zero }
        let target = estremoMassimo ? hi : lo
        let tolerance = max((hi - lo) * 0.02, 1e-5)
        let edge = zip(points, values).compactMap {
            abs($0.1 - target) <= tolerance ? $0.0 : nil
        }
        return edge.reduce(.zero, +) / Float(max(edge.count, 1))
    }

    private func aggiornaModalitaPianiTexturizzati() {
        guard haPianiTexturizzati else {
            pianiTexturizzatiNode.isHidden = true
            sviluppoPianiNode.isHidden = true
            return
        }
        pianiTexturizzatiNode.isHidden = mostraSviluppoPiani
        sviluppoPianiNode.isHidden = !mostraSviluppoPiani
        guard mostraSviluppoPiani else {
            inquadra()
            return
        }
        visteOrtografiche = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.richiediSnap?(SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 1, 0))
            self.richiediZoom?(1.7)
        }
    }

    /// Conserva sorgenti, materiali e triangoli originali del livello OC. Gli
    /// elementi possono cosi' essere ricostruiti senza perdere UV e texture.
    private func registraPartiTexture(
        _ root: SCNNode,
        associaDirettamente: Bool = false
    ) {
        ocTextureParts = []
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let positions = EditableMesh.leggiPosizioni(geometry)
            else { return }

            var elementTriangles: [[SIMD3<UInt32>]] = []
            var elementCentroids: [[SIMD3<Float>]] = []
            for element in geometry.elements where element.primitiveType == .triangles {
                guard let indices = EditableMesh.leggiIndici(element) else { continue }
                var triangles: [SIMD3<UInt32>] = []
                var centroids: [SIMD3<Float>] = []
                triangles.reserveCapacity(indices.count / 3)
                centroids.reserveCapacity(indices.count / 3)
                var i = 0
                while i + 2 < indices.count {
                    let triangle = SIMD3(indices[i], indices[i + 1], indices[i + 2])
                    let a = positions[Int(triangle.x)]
                    let b = positions[Int(triangle.y)]
                    let c = positions[Int(triangle.z)]
                    let local = (a + b + c) / 3
                    let converted = node.convertPosition(
                        SCNVector3(local.x, local.y, local.z), to: contentNode)
                    triangles.append(triangle)
                    centroids.append(SIMD3(converted.x, converted.y, converted.z))
                    i += 3
                }
                elementTriangles.append(triangles)
                elementCentroids.append(centroids)
            }
            guard !elementTriangles.isEmpty else { return }
            ocTextureParts.append(OCTexturePart(
                node: node,
                sources: geometry.sources,
                materials: geometry.materials,
                vertexCount: positions.count,
                triangles: elementTriangles,
                centroids: elementCentroids))
        }
        let total = ocTextureParts.reduce(0) { partial, part in
            partial + part.triangles.reduce(0) { $0 + $1.count }
        }
        var directMatch = associaDirettamente && total == mesh.triangleCount
        if directMatch {
            let (lo, hi) = mesh.aabb
            let tolerance = max(simd_length(hi - lo) * 0.0002, 1e-5)
            let sampleStep = max(1, total / 256)
            var globalIndex = 0
            var checked = 0
            var matched = 0
            for part in ocTextureParts {
                for centroids in part.centroids {
                    for centroid in centroids {
                        if globalIndex.isMultiple(of: sampleStep) {
                            checked += 1
                            let editable = mesh.centroid(mesh.triangles[globalIndex])
                            if simd_distance(centroid, editable) <= tolerance {
                                matched += 1
                            }
                        }
                        globalIndex += 1
                    }
                }
            }
            directMatch = checked > 0 && matched * 100 >= checked * 98
        }
        if directMatch {
            let ids = Array(0..<total)
            textureTriangleIds = ids
            textureTriangleIdsOriginali = ids
        } else {
            textureTriangleIds = nil
            textureTriangleIdsOriginali = nil
        }
    }

    /// Ritaglia la topologia raw texturizzata sulla superficie clean corrente.
    /// La pulizia elimina triangoli senza spostarli: i centroidi permettono una
    /// corrispondenza lineare anche dopo la compattazione degli indici OBJ.
    private func sincronizzaTextureConMesh() {
        guard !ocTextureParts.isEmpty, !mesh.triangles.isEmpty else { return }

        if let ids = textureTriangleIds, ids.count == mesh.triangleCount {
            sincronizzaTextureDirettamente(ids)
            return
        }

        let (lo, hi) = mesh.aabb
        let extent = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
        let tolerance = max(extent * 0.00001, 2e-5)
        let cellSize = tolerance * 4

        func key(_ p: SIMD3<Float>) -> TextureGridKey {
            TextureGridKey(
                x: Int((p.x / cellSize).rounded()),
                y: Int((p.y / cellSize).rounded()),
                z: Int((p.z / cellSize).rounded()))
        }

        let cleanCentroids = mesh.triangles.map(mesh.centroid)
        var grid: [TextureGridKey: [Int]] = [:]
        grid.reserveCapacity(mesh.triangles.count / 2)
        for (index, centroid) in cleanCentroids.enumerated() {
            grid[key(centroid), default: []].append(index)
        }

        let maxDistance2 = tolerance * tolerance
        var mappedIds = [Int](repeating: -1, count: mesh.triangleCount)
        func cleanTriangle(for point: SIMD3<Float>) -> Int? {
            let center = key(point)
            if let candidates = grid[center],
               let match = candidates.first(where: { index in
                   mappedIds[index] < 0 &&
                       simd_length_squared(cleanCentroids[index] - point) <= maxDistance2
               }) {
                return match
            }
            for x in (center.x - 1)...(center.x + 1) {
                for y in (center.y - 1)...(center.y + 1) {
                    for z in (center.z - 1)...(center.z + 1) {
                        if x == center.x, y == center.y, z == center.z { continue }
                        let neighbor = TextureGridKey(x: x, y: y, z: z)
                        if let candidates = grid[neighbor],
                           let match = candidates.first(where: { index in
                               mappedIds[index] < 0 &&
                                   simd_length_squared(cleanCentroids[index] - point) <= maxDistance2
                           }) {
                            return match
                        }
                    }
                }
            }
            return nil
        }

        var originalId = 0
        for part in ocTextureParts {
            var elements: [SCNGeometryElement] = []
            elements.reserveCapacity(part.triangles.count)
            for elementIndex in part.triangles.indices {
                let triangles = part.triangles[elementIndex]
                let centroids = part.centroids[elementIndex]
                var keptIndices: [UInt32] = []
                keptIndices.reserveCapacity(triangles.count * 3)
                for i in triangles.indices {
                    let currentOriginalId = originalId
                    originalId += 1
                    let p = centroids[i]
                    if let cleanIndex = cleanTriangle(for: p) {
                        let t = triangles[i]
                        guard Int(t.x) < part.vertexCount,
                              Int(t.y) < part.vertexCount,
                              Int(t.z) < part.vertexCount
                        else { continue }
                        keptIndices.append(contentsOf: [t.x, t.y, t.z])
                        if mappedIds[cleanIndex] < 0 {
                            mappedIds[cleanIndex] = currentOriginalId
                        }
                    }
                }
                elements.append(SCNGeometryElement(
                    indices: keptIndices, primitiveType: .triangles))
            }
            let geometry = SCNGeometry(sources: part.sources, elements: elements)
            geometry.materials = part.materials
            part.node.geometry = geometry
        }
        if !mappedIds.contains(-1) {
            textureTriangleIds = mappedIds
            textureTriangleIdsOriginali = mappedIds
        }
        aggiornaClip()
    }

    /// Percorso veloce per la raw Object Capture: il taglio cambia soltanto la
    /// compattezza degli array, non l'identita' dei triangoli originali.
    private func sincronizzaTextureDirettamente(_ ids: [Int]) {
        let total = ocTextureParts.reduce(0) { partial, part in
            partial + part.triangles.reduce(0) { $0 + $1.count }
        }
        var kept = [Bool](repeating: false, count: total)
        for id in ids where kept.indices.contains(id) { kept[id] = true }

        var originalId = 0
        for part in ocTextureParts {
            var elements: [SCNGeometryElement] = []
            elements.reserveCapacity(part.triangles.count)
            for triangles in part.triangles {
                var indices: [UInt32] = []
                indices.reserveCapacity(triangles.count * 3)
                for triangle in triangles {
                    if kept[originalId],
                       Int(triangle.x) < part.vertexCount,
                       Int(triangle.y) < part.vertexCount,
                       Int(triangle.z) < part.vertexCount {
                        indices.append(contentsOf: [triangle.x, triangle.y, triangle.z])
                    }
                    originalId += 1
                }
                elements.append(SCNGeometryElement(
                    indices: indices, primitiveType: .triangles))
            }
            let geometry = SCNGeometry(sources: part.sources, elements: elements)
            geometry.materials = part.materials
            part.node.geometry = geometry
        }
        aggiornaClip()
    }

    private func rimappaTexture(_ remap: [Int]) {
        guard let oldIds = textureTriangleIds, oldIds.count == remap.count else {
            textureTriangleIds = nil
            return
        }
        let newCount = remap.max().map { $0 + 1 } ?? 0
        var newIds = [Int](repeating: -1, count: newCount)
        for oldIndex in remap.indices {
            let newIndex = remap[oldIndex]
            if newIndex >= 0 { newIds[newIndex] = oldIds[oldIndex] }
        }
        textureTriangleIds = newIds
    }

    nonisolated private static func caricaOBJEditabile(_ url: URL) -> EditableMesh? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let bytes = [UInt8](data)
        let n = bytes.count
        var i = 0
        var verts: [SIMD3<Float>] = []
        var tris: [SIMD3<UInt32>] = []
        verts.reserveCapacity(max(1024, n / 70))
        tris.reserveCapacity(max(1024, n / 40))

        @inline(__always) func isSpace(_ c: UInt8) -> Bool {
            c == 32 || c == 9 || c == 13
        }

        @inline(__always) func isNewline(_ c: UInt8) -> Bool {
            c == 10 || c == 13
        }

        func skipSpaces() {
            while i < n, isSpace(bytes[i]) { i += 1 }
        }

        func skipLine() {
            while i < n, !isNewline(bytes[i]) { i += 1 }
            while i < n, isNewline(bytes[i]) { i += 1 }
        }

        func parseInt() -> Int? {
            skipSpaces()
            guard i < n else { return nil }
            var sign = 1
            if bytes[i] == 45 {
                sign = -1
                i += 1
            } else if bytes[i] == 43 {
                i += 1
            }
            var value = 0
            var found = false
            while i < n {
                let c = bytes[i]
                guard c >= 48, c <= 57 else { break }
                value = value * 10 + Int(c - 48)
                found = true
                i += 1
            }
            return found ? value * sign : nil
        }

        func parseFloat() -> Float? {
            skipSpaces()
            guard i < n else { return nil }
            var sign: Double = 1
            if bytes[i] == 45 {
                sign = -1
                i += 1
            } else if bytes[i] == 43 {
                i += 1
            }

            var value: Double = 0
            var found = false
            while i < n {
                let c = bytes[i]
                guard c >= 48, c <= 57 else { break }
                value = value * 10 + Double(c - 48)
                found = true
                i += 1
            }

            if i < n, bytes[i] == 46 {
                i += 1
                var scale: Double = 0.1
                while i < n {
                    let c = bytes[i]
                    guard c >= 48, c <= 57 else { break }
                    value += Double(c - 48) * scale
                    scale *= 0.1
                    found = true
                    i += 1
                }
            }

            if i < n, bytes[i] == 69 || bytes[i] == 101 {
                i += 1
                var expSign = 1
                if i < n, bytes[i] == 45 {
                    expSign = -1
                    i += 1
                } else if i < n, bytes[i] == 43 {
                    i += 1
                }
                var exp = 0
                var hasExp = false
                while i < n {
                    let c = bytes[i]
                    guard c >= 48, c <= 57 else { break }
                    exp = exp * 10 + Int(c - 48)
                    hasExp = true
                    i += 1
                }
                if hasExp { value *= pow(10, Double(exp * expSign)) }
            }

            return found ? Float(value * sign) : nil
        }

        func indiceVertice(_ raw: Int) -> Int? {
            let idx: Int
            if raw > 0 {
                idx = raw - 1
            } else if raw < 0 {
                idx = verts.count + raw
            } else {
                return nil
            }
            return (idx >= 0 && idx < verts.count) ? idx : nil
        }

        while i < n {
            skipSpaces()
            guard i < n else { break }
            if bytes[i] == 35 || isNewline(bytes[i]) {
                skipLine()
                continue
            }

            if bytes[i] == 118, i + 1 < n, isSpace(bytes[i + 1]) {
                i += 1
                if let x = parseFloat(), let y = parseFloat(), let z = parseFloat() {
                    verts.append(SIMD3<Float>(x, y, z))
                }
                skipLine()
                continue
            }

            if bytes[i] == 102, i + 1 < n, isSpace(bytes[i + 1]) {
                i += 1
                var ids: [Int] = []
                ids.reserveCapacity(8)
                while i < n {
                    skipSpaces()
                    if i >= n || isNewline(bytes[i]) { break }
                    if let raw = parseInt(), let id = indiceVertice(raw) {
                        ids.append(id)
                    }
                    while i < n, !isSpace(bytes[i]), !isNewline(bytes[i]) { i += 1 }
                }
                guard ids.count >= 3 else {
                    skipLine()
                    continue
                }
                let a = ids[0]
                for k in 1..<(ids.count - 1) {
                    tris.append(SIMD3<UInt32>(UInt32(a), UInt32(ids[k]), UInt32(ids[k + 1])))
                }
                skipLine()
                continue
            }

            skipLine()
        }
        guard verts.count >= 3, !tris.isEmpty else { return nil }
        return EditableMesh(vertices: verts, triangles: tris)
    }

    /// Chiede alla vista di re-inquadrare tutta la mesh (frameNodes del
    /// camera controller). La mesh OC è in coordinate arbitrarie: nessuna
    /// assunzione su scala/origine.
    func inquadra() { reframeTick += 1 }

    /// Buffer della mesh editabile (per il taglio distruttivo, Fase 3).
    /// Disponibile solo quando la mesh è una geometria singola (demo / OBJ
    /// flatten futuro), non per gerarchie multi-nodo.
    var geometriaEditabile: SCNGeometry? { contentNode.geometry }

    // MARK: Box di lavoro + crop (§1)

    /// Allinea il box alla facciata: se c'è il piano base usa quello (preciso),
    /// altrimenti la PCA della geometria. NON ruota la mesh, solo il box.
    func allineaBox() {
        if assiManualiFissati {
            allineaBoxAgliAssiNavigazione()
            return
        }
        if haPianoBase { allineaBoxAlPianoBase(); return }
        // Piano dominante (facciata) via RANSAC; fallback PCA grezza.
        let ob = mesh.orientedBoxRANSAC() ?? mesh.orientedBox()
        frameOrigin = ob.origin
        boxRot = ob.rot
        let margine = (ob.hi - ob.lo) * 0.02
        boxLo = ob.lo - margine
        boxHi = ob.hi + margine
        ricostruisciBox()
    }

    /// Reset assi-allineato al mondo (box dritto sul bounding box della mesh).
    func resetBox() {
        boxRot = matrix_identity_float3x3
        frameOrigin = .zero
        let (lo, hi) = mesh.aabb
        let margine = (hi - lo) * 0.02
        boxLo = lo - margine
        boxHi = hi + margine
        ricostruisciBox()
    }

    /// Aggiorna una faccia del box trascinata (coord nel frame LOCALE del box).
    func aggiornaFacciaBox(_ f: FacciaBox, coord: Float) {
        let a = f.asse
        let minimo: Float = 1e-4
        if f.isMin { boxLo[a] = min(coord, boxHi[a] - minimo) }
        else       { boxHi[a] = max(coord, boxLo[a] + minimo) }
        ricostruisciBox()
    }

    /// Crop: elimina i poligoni fuori dal box orientato (o dentro, se `inverti`).
    func applicaCrop(inverti: Bool) {
        let sel = inverti ? mesh.triangoliDentro(frameOrigin, boxRot, boxLo, boxHi)
                          : mesh.triangoliFuori(frameOrigin, boxRot, boxLo, boxHi)
        guard !sel.isEmpty else { return }
        annullaRevisionePiani()
        registraUndo()
        let remap = mesh.elimina(sel)
        rimappaTexture(remap)
        meshRevision += 1
        rimappaFacce(remap)
        if !inverti { ritagliaPianiAlBox() }
        selezione = []
        renderMesh()
    }

    /// Hit-test sulle maniglie del box (dal Coordinator). Ritorna la faccia.
    func facciaBox(perNome nome: String?) -> FacciaBox? {
        guard let n = nome, n.hasPrefix("box:") else { return nil }
        return FacciaBox(rawValue: String(n.dropFirst(4)))
    }

    /// Centro di una faccia in coordinate LOCALI del box.
    private func centroFacciaLocale(_ f: FacciaBox) -> SIMD3<Float> {
        var p = (boxLo + boxHi) / 2
        p[f.asse] = f.isMin ? boxLo[f.asse] : boxHi[f.asse]
        return p
    }

    /// Centro di una faccia in WORLD (per profondità/drag dal Coordinator).
    func centroFaccia(_ f: FacciaBox) -> SIMD3<Float> {
        frameOrigin + boxRot * centroFacciaLocale(f)
    }

    /// Converte un punto world nel frame locale del box (per il drag maniglie).
    func worldInLocaleBox(_ w: SIMD3<Float>) -> SIMD3<Float> {
        boxRot.transpose * (w - frameOrigin)
    }

    /// Aggiorna i parametri di clip del materiale mesh dal box corrente.
    /// In modalità Box il clip è attivo → la mesh fuori dal box sparisce.
    private func aggiornaClip() {
        var materials = contentNode.geometry?.materials ?? []
        materials.append(contentsOf: ocTextureParts.flatMap(\.materials))
        pianiNode.enumerateHierarchy { node, _ in
            if let nodeMaterials = node.geometry?.materials {
                materials.append(contentsOf: nodeMaterials)
            }
        }
        guard !materials.isEmpty else { return }
        let clipAttivo = strumento == .box
        let rt = boxRot.transpose
        let t = -(rt * frameOrigin)
        let inv = simd_float4x4(
            SIMD4<Float>(rt.columns.0, 0),
            SIMD4<Float>(rt.columns.1, 0),
            SIMD4<Float>(rt.columns.2, 0),
            SIMD4<Float>(t, 1))
        for material in materials {
            material.shaderModifiers = clipAttivo ? [.surface: MeshFactory.clipModifier] : nil
            material.setValue(SCNVector3(boxLo.x, boxLo.y, boxLo.z), forKey: "clipLo")
            material.setValue(SCNVector3(boxHi.x, boxHi.y, boxHi.z), forKey: "clipHi")
            material.setValue(NSValue(scnMatrix4: SCNMatrix4(inv)), forKey: "clipInv")
            material.setValue(Float(clipAttivo ? 1 : 0), forKey: "clipOn")
        }
    }

    private func ricostruisciBox() {
        aggiornaClip()
        boxNode.isHidden = strumento != .box
        // Posiziona/orienta il nodo box; wireframe e maniglie sono in coord locali.
        let r0 = boxRot.columns.0, r1 = boxRot.columns.1, r2 = boxRot.columns.2
        boxNode.simdTransform = simd_float4x4(
            SIMD4(r0.x, r0.y, r0.z, 0),
            SIMD4(r1.x, r1.y, r1.z, 0),
            SIMD4(r2.x, r2.y, r2.z, 0),
            SIMD4(frameOrigin.x, frameOrigin.y, frameOrigin.z, 1))

        boxNode.childNodes.forEach { $0.removeFromParentNode() }
        boxNode.geometry = MeshFactory.boxWireframe(
            boxLo, boxHi, colore: UIColor(EditorTheme.accento))

        // Maniglie: grip visivo piccolo, area di presa più grande per touch.
        let ext = max(boxHi.x - boxLo.x, max(boxHi.y - boxLo.y, boxHi.z - boxLo.z))
        let s = CGFloat(max(ext * 0.022, 0.001))
        for f in [FacciaBox.xMin, .xMax, .yMin, .yMax, .zMin, .zMax] {
            let nodo = SCNNode()
            nodo.name = "box:\(f.rawValue)"
            nodo.renderingOrder = 1000
            let c = centroFacciaLocale(f)
            nodo.position = SCNVector3(c.x, c.y, c.z)
            // Cubo bianco + leggero alone arancione per la presa.
            let presa = SCNNode(geometry: SCNBox(width: s * 3.4, height: s * 3.4, length: s * 3.4, chamferRadius: s * 0.4))
            presa.name = "box:\(f.rawValue)"
            presa.geometry?.materials = [maniglia(UIColor(EditorTheme.accento).withAlphaComponent(0.18))]
            let alone = SCNNode(geometry: SCNBox(width: s * 2.0, height: s * 2.0, length: s * 2.0, chamferRadius: s * 0.3))
            alone.geometry?.materials = [maniglia(UIColor(EditorTheme.accento).withAlphaComponent(0.45))]
            let grip = SCNNode(geometry: SCNBox(width: s, height: s, length: s, chamferRadius: s * 0.2))
            grip.geometry?.materials = [maniglia(.white)]
            nodo.addChildNode(presa)
            nodo.addChildNode(alone)
            nodo.addChildNode(grip)
            boxNode.addChildNode(nodo)
        }
    }

    private func maniglia(_ colore: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false   // sempre visibili sopra la mesh
        m.writesToDepthBuffer = false
        return m
    }

    // MARK: Selezione + taglio (T1)

    func selezionaTutto() { selezione = Set(0..<mesh.triangleCount); ridisegnaSelezione() }
    func deselezionaTutto() { selezione = []; ridisegnaSelezione() }
    func invertiSelezione() {
        selezione = Set(0..<mesh.triangleCount).subtracting(selezione); ridisegnaSelezione()
    }
    func selezionaFrammenti() { selezione = mesh.frammenti(); ridisegnaSelezione() }
    func espandiSelezione() { selezione = mesh.espandi(selezione); ridisegnaSelezione() }
    func restringiSelezione() { selezione = mesh.restringi(selezione); ridisegnaSelezione() }

    /// Applica una selezione da lazo (calcolata dalla vista proiettando i
    /// triangoli). `aggiungi`: somma alla selezione invece di sostituirla.
    func applicaLazo(_ idx: Set<Int>, aggiungi: Bool) {
        selezione = aggiungi ? selezione.union(idx) : idx
        ridisegnaSelezione()
    }

    func aggiornaLazoPoligonalePunti(_ n: Int) {
        numPuntiLazoPoligonale = n
    }

    func resetLazoPoligonale() {
        lazoPoligonaleResetTick += 1
        numPuntiLazoPoligonale = 0
        deselezionaTutto()
    }

    func chiudiLazoPoligonale() {
        lazoPoligonaleApplyTick += 1
    }

    /// Aggiunge triangoli alla selezione (usato dal pennello, in continuo).
    func aggiungiAllaSelezione(_ idx: Set<Int>) {
        guard !idx.isSubset(of: selezione) else { return }
        selezione.formUnion(idx)
        ridisegnaSelezione()
    }

    /// Cancella i triangoli selezionati dalla mesh (distruttivo, con undo).
    func eliminaSelezione() {
        guard !selezione.isEmpty else { return }
        annullaRevisionePiani()
        registraUndo()
        let remap = mesh.elimina(selezione)
        rimappaTexture(remap)
        meshRevision += 1
        rimappaFacce(remap)
        selezione = []
        if modoSelezione == .poligonale { resetLazoPoligonale() }
        renderMesh()
    }

    func registraUndo() {
        invalidaPianiTexturizzatiLocali()
        undoStack.append((mesh, selezione, facce, textureTriangleIds))
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        puoUndo = true; puoRedo = false
        workspaceRevision += 1
    }

    func concludiModificaPersistente() {
        invalidaPianiTexturizzatiLocali()
        workspaceRevision += 1
    }

    /// Un bundle proiettato appartiene a una specifica revisione dei piani.
    /// Appena la geometria cambia non deve restare sovrapposto alla revisione
    /// nuova, altrimenti texture e spigoli sembrano ruotati o scollegati.
    private func invalidaPianiTexturizzatiLocali() {
        guard haPianiTexturizzati else { return }
        pianiTexturizzatiNode.childNodes.forEach { $0.removeFromParentNode() }
        sviluppoPianiNode.childNodes.forEach { $0.removeFromParentNode() }
        haPianiTexturizzati = false
        mostraSviluppoPiani = false
        pianiTexturizzatiNode.isHidden = true
        sviluppoPianiNode.isHidden = true
        mostraMesh = true
    }

    func undo() {
        guard let (m, s, f, textureIds) = undoStack.popLast() else { return }
        annullaRevisionePiani()
        redoStack.append((mesh, selezione, facce, textureTriangleIds))
        mesh = m; selezione = s; facce = f; textureTriangleIds = textureIds
        meshRevision += 1
        workspaceRevision += 1
        puoUndo = !undoStack.isEmpty; puoRedo = true
        renderMesh()
    }

    func redo() {
        guard let (m, s, f, textureIds) = redoStack.popLast() else { return }
        annullaRevisionePiani()
        undoStack.append((mesh, selezione, facce, textureTriangleIds))
        mesh = m; selezione = s; facce = f; textureTriangleIds = textureIds
        meshRevision += 1
        workspaceRevision += 1
        puoUndo = true; puoRedo = !redoStack.isEmpty
        renderMesh()
    }

    // MARK: Facce proxy — pennelli colorati (§3)

    var facciaAttiva: FacciaProxy? { facce.first { $0.id == facciaAttivaId } }

    @Published var segmentando = false

    /// Riconosce le facce PARTENDO DAI SEGNI del pennello: per ogni faccia che
    /// ha una pennellata, cresce al suo piano (per appartenenza) e fitta il
    /// piano. Senza segni non rileva nulla. Off-main con spinner.
    func riconosciFacce() async {
        guard !segmentando else { return }
        let semi: [(id: Int, seed: Set<Int>)] = facce
            .filter { !$0.triangoli.isEmpty }
            .map { (id: $0.id, seed: $0.triangoli) }
        guard !semi.isEmpty else { return }   // niente segno → niente riconoscimento
        segmentando = true
        registraUndo()
        let m = mesh
        let tol = Float(tolleranzaNormaleGradi)
        let adj = adiacenza()   // costruita una volta, condivisa da tutti i semi
        let risultati = await Task.detached(priority: .userInitiated) {
            () -> [(id: Int, tri: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] in
            var out: [(Int, Set<Int>, SIMD3<Float>, SIMD3<Float>)] = []
            for s in semi {
                guard let (p, n) = m.fitPianoRANSAC(s.seed) else { continue }
                let cresciuto = m.crescePianare(da: s.seed, normale: n, punto: p, tolGradi: tol, adiacenza: adj)
                let (p2, n2) = m.fitPianoRANSAC(cresciuto) ?? (p, n)
                out.append((s.id, cresciuto, p2, n2))
            }
            return out
        }.value

        for r in risultati {
            guard let i = facce.firstIndex(where: { $0.id == r.id }) else { continue }
            for j in facce.indices where facce[j].id != r.id { facce[j].triangoli.subtract(r.tri) }
            facce[i].triangoli = r.tri
            facce[i].pianoPunto = r.punto
            facce[i].pianoNormale = r.normale
            facce[i].erroreRms = mesh.rmsDalPiano(r.tri, punto: r.punto, normale: r.normale)
        }
        mergeComplanariConnessi()      // #14
        stimaGravita()                 // #15
        scartaNonPlanari()             // #9
        scartaSlivers()                // #10
        scartaPianiPiccoli()           // #8
        classificaPerGravita()         // #7
        generaPoligoniTutti()          // Fase B: poligono editabile per ogni piano
        if facciaAttivaId == nil || !facce.contains(where: { $0.id == facciaAttivaId }) {
            facciaAttivaId = facce.first?.id
        }
        pianiGenerati = facce.count
        mostraPiani = true
        ridisegnaFacce()
        ridisegnaPiani()
        segmentando = false
    }

    /// Rileva AUTOMATICAMENTE le facciate principali sull'INTERA mesh: stima gli
    /// assi dominanti dell'edificio (Manhattan/Atlanta), cerca piani coerenti con
    /// quegli assi e li mostra come candidati selezionabili.
    @MainActor
    func segmentaTuttoAutomatico() async {
        guard !segmentando, !mesh.triangles.isEmpty else { return }
        segmentando = true
        cursoreInfo = "Auto piani: avvio…"
        registraUndo()
        let m = mesh
        await Task.yield()
        let piani = await Task.detached(priority: .userInitiated) {
            () -> [(triangoli: Set<Int>, punto: SIMD3<Float>, normale: SIMD3<Float>)] in
            m.segmentaPianiManhattanAtlanta(maxPiani: 28,
                                             maxAssi: 4,
                                             sogliaAsseGradi: 16,
                                             sogliaDistFrazione: 0.010,
                                             minAreaFrazione: 0.00035,
                                             minTriangoliFrazione: 0.00025)
        }.value
        cursoreInfo = "Auto piani: \(piani.count) candidati"

        // Ricostruisci le facce dai piani trovati. Il clustering può raggruppare
        // più pezzi complanari; il passaggio sulle componenti elimina isole minime
        // senza spezzare una facciata interrotta da finestre o lacune.
        facce.removeAll()
        facceSelezionate.removeAll()
        facciaAttivaId = nil
        let minComp = max(Int(Float(mesh.triangles.count) * 0.0008), 12)
        let areaTotale = mesh.areaTriangoli(Set(mesh.triangles.indices))
        for p in piani {
            // Spezza in componenti connesse, SCARTA le isole piccole/lontane (rumore,
            // pezzi sull'altro lato dell'edificio) e RIUNISCI quelle grandi: un muro
            // forato dalle finestre resta UN piano, ma niente più inlier vaganti.
            let comps = mesh.componentiConnesse(p.triangoli)
            let aree = comps.map { mesh.areaTriangoli($0) }
            let maxAreaComp = aree.max() ?? 0
            let sogliaArea = max(areaTotale * 0.00012, maxAreaComp * 0.015)
            var tri = Set<Int>()
            for (c, a) in zip(comps, aree) where c.count >= minComp / 3 && a >= sogliaArea {
                tri.formUnion(c)
            }
            if tri.count < minComp {
                tri = p.triangoli
            }
            guard !tri.isEmpty else { continue }
            let (cp, cn) = mesh.fitPianoRANSAC(tri) ?? (p.punto, p.normale)
            let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
            var f = FacciaProxy(id: prossimoIdFaccia, nome: "Piano \(prossimoIdFaccia)", colore: colore)
            prossimoIdFaccia += 1
            f.triangoli = tri
            f.pianoPunto = cp
            f.pianoNormale = cn
            f.erroreRms = mesh.rmsDalPiano(tri, punto: cp, normale: cn)
            facce.append(f)
        }

        // Stessa pulizia del flusso manuale.
        mergeComplanariConnessi()
        stimaGravita()
        stimaGravitaDaMuri()           // "su" dai muri verticali → rettangoli dritti
        classificaPerGravita()
        tieniFacciatePrincipali()
        applicaFiltriProfilo()         // balconi/sporgenze secondo il profilo di rilievo
        generaPoligoniTutti()
        facciaAttivaId = facce.first?.id
        pianiGenerati = facce.count
        mostraProxy = true
        mostraPiani = true
        ridisegnaFacce()
        ridisegnaPiani()
        cursoreInfo = "Auto piani: \(piani.count) candidati → \(facce.count) facce"
        segmentando = false
    }

    /// Auto-proposta architettonica vincolata agli assi edificio/manuali:
    /// istogrammi di area su Z (facciate/torrette) e X (spallette), quad puliti.
    @MainActor
    func segmentaPianiBCS() async {
        guard !segmentando, !mesh.triangles.isEmpty else { return }
        segmentando = true
        cursoreInfo = "Auto BCS: istogrammi assi…"
        registraUndo()
        // Assi dalla navigazione (gravità + fronte): aderenti alla facciata. La PCA
        // sulle posizioni dà bene la normale ma ruota il "su" → la scarto.
        calcolaAssiNavigazione()
        let assi = assiNav
        let m = mesh
        let binMetri = bcsBinMetri
        let angTolGradi = bcsAngTolGradi
        let minAreaFacciata = bcsMinAreaFacciata
        let minAreaSpalletta = bcsMinAreaSpalletta
        let maxFacciate = bcsMaxFacciate
        let maxSpallette = bcsMaxSpallette
        await Task.yield()
        let piani = await Task.detached(priority: .userInitiated) {
            m.segmentaPianiBCS(assi: (right: assi.r, up: assi.u, front: assi.n),
                               binMetri: binMetri,
                               angTolGradi: angTolGradi,
                               minAreaFacciata: minAreaFacciata,
                               minAreaSpalletta: minAreaSpalletta,
                               maxFacciate: maxFacciate,
                               maxSpallette: maxSpallette,
                               percLo: 5,
                               percHi: 95)
        }.value

        facce.removeAll()
        facceSelezionate.removeAll()
        facciaAttivaId = nil
        for p in piani {
            let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
            let prefisso = p.tipo == .spalletta ? "Spalletta" : "Facciata"
            var f = FacciaProxy(id: prossimoIdFaccia, nome: "\(prefisso) \(prossimoIdFaccia)", colore: colore)
            prossimoIdFaccia += 1
            f.tipo = p.tipo
            f.pianoPunto = p.punto
            f.pianoNormale = p.normale
            f.poligono = p.corners
            facce.append(f)
        }
        facciaAttivaId = facce.first?.id
        pianiGenerati = facce.count
        mostraProxy = true
        mostraPiani = true
        ridisegnaFacce()
        ridisegnaPiani()
        let spallette = facce.filter { $0.tipo == .spalletta }.count
        let facciate = facce.count - spallette
        cursoreInfo = "Auto BCS: \(facciate) facciate, \(spallette) spallette"
        segmentando = false
    }

    /// Riconoscimento piani via backend: il client indica esplicitamente se
    /// analizzare la mesh OC raw o la revisione clean salvata nello storage.
    func riconosciPianiAuto(sessionId: String, meshKind: String? = nil) async {
        guard !segmentando, !mesh.triangles.isEmpty else { return }
        segmentando = true
        let revisionAtStart = meshRevision
        cursoreInfo = "Riconosco i piani…"
        // La gravità della mesh OC/ARKit è l'asse Y del suo frame. NON passare l'up
        // stimato (assiNav.u): esce inclinato → i piani vengono RUOTATI. La gravità
        // nota [0,1,0] tiene i piani dritti (normali orizzontali).
        do {
            let r = try await BackendAPIClient.shared.detectPlanes(
                sessionId: sessionId, up: [0, 1, 0], meshKind: meshKind)
            guard meshRevision == revisionAtStart else {
                cursoreInfo = "Mesh modificata: ricalcolo piani necessario"
                segmentando = false
                return
            }
            applicaPianiRilevati(r.planes)
            let sorgente = r.mesh_kind == "raw" ? "mesh OC originale" : "mesh pulita"
            cursoreInfo = "Piani riconosciuti: \(facce.count) · \(sorgente)"
        } catch {
            cursoreInfo = "Riconoscimento fallito: \(error.localizedDescription)"
        }
        segmentando = false
    }

    /// Sostituisce le facce coi piani rilevati dal backend (quad + tipo).
    func applicaPianiRilevati(
        _ planes: [BackendAPIClient.DetectedPlane],
        registraModifica: Bool = true
    ) {
        if registraModifica { registraUndo() }
        facce.removeAll(); facceSelezionate.removeAll(); facciaAttivaId = nil
        for p in planes {
            let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
            var f = FacciaProxy(id: prossimoIdFaccia, nome: p.nome, colore: colore)
            prossimoIdFaccia += 1
            switch p.tipo {
            case "spalla", "spalletta": f.tipo = .spalletta
            case "falda":       f.tipo = .torretta      // obliquo (timpano/mansarda)
            case "orizzontale": f.tipo = .orizzontale
            default:            f.tipo = .facciata
            }
            if p.punto.count == 3 { f.pianoPunto = SIMD3<Float>(p.punto[0], p.punto[1], p.punto[2]) }
            if p.normale.count == 3 { f.pianoNormale = SIMD3<Float>(p.normale[0], p.normale[1], p.normale[2]) }
            f.poligono = p.corners.compactMap { c in
                c.count == 3 ? SIMD3<Float>(c[0], c[1], c[2]) : nil
            }
            if let tri = p.triangoli {
                // Gli indici appartengono esattamente alla revisione inviata al
                // detector. Non importare mai riferimenti fuori dai buffer.
                f.triangoli = Set(tri.filter { mesh.triangles.indices.contains($0) })
            }
            facce.append(f)
        }
        facciaAttivaId = facce.first?.id
        pianiGenerati = facce.count
        mostraProxy = false; mostraPiani = true
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// #14 — Unisce facce COMPLANARI e CONNESSE (stesso muro spezzato dalle
    /// finestre o segnato con più tratti). Due torrette complanari ma staccate
    /// NON si fondono (test `adiacenti`).
    /// Filtri finali dal profilo di rilievo: scarta i balconi (solette orizzontali
    /// locali a mezza altezza) e, se richiesto, le sporgenze (torrette/bovindi).
    private func applicaFiltriProfilo() {
        if !profTieniSporgenze {
            facce.removeAll { $0.tipo == .torretta || $0.tipo == .spalletta }
        }
        guard profIgnoraBalconi, !facce.isEmpty else { return }
        let su = simd_normalize(gravitaSu)
        let (lo, hi) = mesh.aabb
        let quotaLo = simd_dot(lo, su), quotaHi = simd_dot(hi, su)
        let H = max(quotaHi - quotaLo, estensioneMesh * 0.2)
        let totale = mesh.areaTriangoli(Set(mesh.triangles.indices))
        facce.removeAll { f in
            guard f.tipo == .orizzontale, !f.triangoli.isEmpty else { return false }
            let a = mesh.areaTriangoli(f.triangoli)
            var qmin = Float.greatestFiniteMagnitude, qmax = -qmin
            for ti in f.triangoli {
                let q = simd_dot(mesh.centroid(mesh.triangles[ti]), su)
                qmin = min(qmin, q); qmax = max(qmax, q)
            }
            let nearTop = qmax > quotaHi - H * 0.18      // tetto/gronda → tieni
            let nearBottom = qmin < quotaLo + H * 0.08   // terreno → lo gestisce già il keep
            let piccola = a < totale * 0.05
            return piccola && !nearTop && !nearBottom     // soletta locale a mezza altezza = balcone/cornice
        }
    }

    private func mergeComplanariConnessi() {
        // Offset max dal profilo (in metri, mesh metrica): la torretta a +1 m NON si fonde.
        let tolOffset = max(profTolMergeM, estensioneMesh * 0.002)
        var unito = true
        while unito {
            unito = false
            ricerca: for i in facce.indices {
                for j in facce.indices where j > i {
                    guard let ni = facce[i].pianoNormale, let pi = facce[i].pianoPunto,
                          let nj = facce[j].pianoNormale, let pj = facce[j].pianoPunto,
                          !facce[i].triangoli.isEmpty, !facce[j].triangoli.isEmpty else { continue }
                    let paralleli = abs(simd_dot(ni, nj)) > 0.985
                    let stessoOffset = abs(simd_dot(pj - pi, ni)) < tolOffset
                    guard paralleli, stessoOffset,
                          mesh.adiacenti(facce[i].triangoli, facce[j].triangoli) else { continue }
                    facce[i].triangoli.formUnion(facce[j].triangoli)
                    if let (p2, n2) = mesh.fitPianoRANSAC(facce[i].triangoli) {
                        facce[i].pianoPunto = p2; facce[i].pianoNormale = n2
                        facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p2, normale: n2)
                    }
                    facce.remove(at: j)
                    unito = true
                    break ricerca
                }
            }
        }
    }

    /// #15 — Stima il verso "su" dalla mesh: media (pesata per area) delle normali
    /// delle facce ~orizzontali. Più affidabile di world-Y su modelli leggermente
    /// storti. Sostituibile col vettore gravità reale delle pose ARKit.
    private func stimaGravita() {
        let y = SIMD3<Float>(0, 1, 0)
        var acc = SIMD3<Float>(0, 0, 0); var peso: Float = 0
        for f in facce {
            guard let n = f.pianoNormale else { continue }
            let nn = simd_dot(n, y) < 0 ? -n : n           // orienta verso l'alto mondiale
            if abs(simd_dot(nn, y)) > 0.85 {               // faccia quasi orizzontale
                let a = mesh.areaTriangoli(f.triangoli)
                acc += nn * a; peso += a
            }
        }
        gravitaSu = (peso > 0 && simd_length(acc) > 1e-4) ? simd_normalize(acc) : y
    }

    /// Stima "su" dai MURI verticali, non dal terreno: l'asse è ortogonale a
    /// tutte le normali dei muri (per ogni coppia non parallela, `n_i × n_j`
    /// punta lungo la verticale dell'edificio). Robusto al terreno inclinato →
    /// rettangoli dritti. Usa la stima del terreno solo come fallback.
    private func stimaGravitaDaMuri() {
        let y = SIMD3<Float>(0, 1, 0)
        let muri = facce.compactMap { $0.pianoNormale }.map { simd_normalize($0) }
            .filter { abs(simd_dot($0, gravitaSu)) < 0.6 }   // ~verticali rispetto alla stima corrente
        guard muri.count >= 2 else { return }
        var up = SIMD3<Float>(0, 0, 0)
        for i in 0..<muri.count {
            for j in (i + 1)..<muri.count {
                var c = simd_cross(muri[i], muri[j])
                let l = simd_length(c)
                if l < 0.34 { continue }                     // muri quasi paralleli: niente info sull'asse
                c /= l
                if simd_dot(c, y) < 0 { c = -c }             // orienta verso l'alto mondiale
                up += c * l                                  // peso = sin(angolo tra i muri)
            }
        }
        if simd_length(up) > 1e-3 { gravitaSu = simd_normalize(up) }
    }

    /// #7 — Classifica ogni piano per angolo rispetto alla verticale (gravità stimata).
    private func classificaPerGravita() {
        for i in facce.indices {
            guard let n = facce[i].pianoNormale else { continue }
            let cosUp = abs(simd_dot(simd_normalize(n), gravitaSu))
            facce[i].tipo = cosUp > 0.7 ? .orizzontale : .facciata   // >70%≈ entro 45° dalla verticale
        }
    }

    /// #9 — Scarta i piani troppo poco planari (RMS alto = superficie curva/rumorosa,
    /// non un vero piano).
    private func scartaNonPlanari() {
        let maxRms = estensioneMesh * 0.03   // 3% del lato: ben oltre il rumore OC
        facce.removeAll { f in
            guard !f.triangoli.isEmpty, let p = f.pianoPunto, let n = f.pianoNormale else { return false }
            return mesh.rmsDalPiano(f.triangoli, punto: p, normale: n) > maxRms
        }
    }

    /// #10 — Scarta strisce/regioni mal proporzionate: bounding-box nel piano molto
    /// allungato (aspect estremo) o riempimento basso (frammenti sparsi).
    private func scartaSlivers() {
        facce.removeAll { f in
            guard !f.triangoli.isEmpty, let n = f.pianoNormale else { return false }
            var right = simd_cross(gravitaSu, n)
            if simd_length(right) < 1e-5 { right = simd_cross(SIMD3(1, 0, 0), n) }
            right = simd_normalize(right)
            let up = simd_normalize(simd_cross(n, right))
            var minx = Float.greatestFiniteMagnitude, maxx = -minx, miny = minx, maxy = -minx
            for i in f.triangoli {
                let c = mesh.centroid(mesh.triangles[i])
                let x = simd_dot(c, right), y = simd_dot(c, up)
                minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
            }
            let w = max(maxx - minx, 1e-5), h = max(maxy - miny, 1e-5)
            let fill = mesh.areaTriangoli(f.triangoli) / (w * h)
            let aspect = max(w, h) / min(w, h)
            return fill < 0.08 || aspect > 30
        }
    }

    /// #8 — Scarta i piani la cui area è sotto soglia (micro-piani / tratti non cresciuti).
    private func scartaPianiPiccoli() {
        let totale = mesh.areaTriangoli(Set(mesh.triangles.indices))
        guard totale > 0 else { return }
        let minArea = totale * 0.00015   // tieni anche spallette/torrette; i micro-rilievi cadono dopo
        facce.removeAll { !$0.triangoli.isEmpty && mesh.areaTriangoli($0.triangoli) < minArea }
    }

    /// Auto piani deve produrre proxy architettonici, non tutti i piani geometrici.
    /// Regole:
    /// - pochi muri principali sempre ammessi;
    /// - secondari solo se verticali e strutturali (bassi, alti, spallette/torrette);
    /// - piani non verticali solo se ampi e leggibili;
    /// - massimo per asse per evitare raffiche di piani paralleli da balconi/rilievi.
    private func tieniFacciatePrincipali() {
        let totale = mesh.areaTriangoli(Set(mesh.triangles.indices))
        guard totale > 0, !facce.isEmpty else { return }

        struct Metrica {
            let index: Int
            let id: Int
            let area: Float
            let normale: SIMD3<Float>
            let punto: SIMD3<Float>
            let centro: SIMD3<Float>
            let verticale: Bool
            let orizzontale: Bool
            let quotaMin: Float
            let quotaMax: Float
            let larghezza: Float
            let altezza: Float
            let fill: Float
            let asse: Int
            var score: Float
            var keep: Bool
            var tipo: TipoFaccia
        }

        let (lo, hi) = mesh.aabb
        let su = simd_normalize(gravitaSu)
        let quotaLo = simd_dot(lo, su)
        let quotaHi = simd_dot(hi, su)
        let altezzaMesh = max(quotaHi - quotaLo, estensioneMesh * 0.2)
        let aree = facce.map { mesh.areaTriangoli($0.triangoli) }
        guard let maxArea = aree.max(), maxArea > 0 else { return }

        func asseKey(_ n0: SIMD3<Float>) -> Int {
            var n = simd_normalize(n0)
            if simd_dot(n, su) < 0 { n = -n }
            let verticale = abs(simd_dot(n, su)) < 0.65
            if !verticale { return 100 }
            let h = simd_normalize(n - simd_dot(n, su) * su)
            let a = atan2(h.z, h.x)
            let step = Float.pi / 8
            return Int((a / step).rounded())
        }

        func metriche(index: Int, f: FacciaProxy, area: Float) -> Metrica? {
            guard let n0 = f.pianoNormale, let p = f.pianoPunto, !f.triangoli.isEmpty else { return nil }
            let n = simd_normalize(n0)
            let cosUp = abs(simd_dot(n, su))
            let verticale = cosUp < 0.55
            let orizzontale = cosUp > 0.78
            var right = simd_cross(su, n)
            if simd_length(right) < 1e-5 { right = simd_cross(SIMD3<Float>(1, 0, 0), n) }
            right = simd_normalize(right)
            var minX = Float.greatestFiniteMagnitude, maxX = -minX
            var minY = minX, maxY = -minX
            var quotaMin = minX, quotaMax = -minX
            var centro = SIMD3<Float>(0, 0, 0)
            var count: Float = 0
            for ti in f.triangoli {
                let c = mesh.centroid(mesh.triangles[ti])
                let d = c - p
                let x = simd_dot(d, right)
                let y = simd_dot(c, su)
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                quotaMin = min(quotaMin, y); quotaMax = max(quotaMax, y)
                centro += c
                count += 1
            }
            guard count > 0 else { return nil }
            centro /= count
            let w = max(maxX - minX, 1e-5)
            let h = max(maxY - minY, 1e-5)
            let fill = area / max(w * h, 1e-5)
            return Metrica(index: index,
                           id: f.id,
                           area: area,
                           normale: n,
                           punto: p,
                           centro: centro,
                           verticale: verticale,
                           orizzontale: orizzontale,
                           quotaMin: quotaMin,
                           quotaMax: quotaMax,
                           larghezza: w,
                           altezza: h,
                           fill: fill,
                           asse: asseKey(n),
                           score: 0,
                           keep: false,
                           tipo: f.tipo)
        }

        var m = facce.indices.compactMap { metriche(index: $0, f: facce[$0], area: aree[$0]) }
        guard !m.isEmpty else { return }

        let principaliIds = Set(m.filter {
            $0.verticale &&
            $0.area >= max(maxArea * sogliaAreaPrincipale, totale * 0.006) &&
            $0.altezza >= altezzaMesh * sogliaAltezzaPrincipale &&
            $0.fill >= 0.035
        }
        .sorted { $0.area > $1.area }
        .prefix(8)
        .map(\.id))

        func vicinoAOPrincipale(_ cand: Metrica) -> Bool {
            for p in m where principaliIds.contains(p.id) {
                let ortogonale = abs(simd_dot(cand.normale, p.normale)) < 0.42
                let parallelo = abs(simd_dot(cand.normale, p.normale)) > 0.94
                let overlapQuota = min(cand.quotaMax, p.quotaMax) - max(cand.quotaMin, p.quotaMin)
                let quotaOk = overlapQuota > min(cand.altezza, p.altezza) * 0.20
                let centroVicino = simd_length(cand.centro - p.centro) < estensioneMesh * 0.45
                let connesso = mesh.adiacenti(cand.index < facce.count ? facce[cand.index].triangoli : [],
                                              p.index < facce.count ? facce[p.index].triangoli : [])
                if quotaOk && (connesso || centroVicino) && (ortogonale || parallelo) { return true }
            }
            return principaliIds.isEmpty
        }

        for i in m.indices {
            let relMax = m[i].area / maxArea
            let relTot = m[i].area / totale
            let hFrac = m[i].altezza / altezzaMesh
            let bassa = m[i].quotaMin < quotaLo + altezzaMesh * 0.24
            let alta = m[i].quotaMax > quotaHi - altezzaMesh * 0.30
            let strutturale = vicinoAOPrincipale(m[i])
            var score = relMax * 70 + relTot * 900
            if m[i].verticale { score += 24 }
            if m[i].orizzontale { score += 4 }
            if principaliIds.contains(m[i].id) { score += 80 }
            if bassa { score += 12 }
            if alta { score += 10 }
            if strutturale { score += 18 }
            if hFrac > 0.18 { score += 12 }
            if m[i].fill < 0.025 { score -= 22 }
            if relMax < 0.020 && !strutturale { score -= 35 }
            if m[i].orizzontale && relMax < 0.045 { score -= 18 }

            let principale = principaliIds.contains(m[i].id)
            let pianoBasso = m[i].verticale && bassa && hFrac > 0.10 && relMax > 0.018 && strutturale
            let torretta = m[i].verticale && alta && hFrac > 0.13 && relMax > 0.014 && strutturale
            let spalletta = m[i].verticale && hFrac > 0.12 && relMax > 0.012 && strutturale
            let copertura = !m[i].verticale && relMax > 0.060 && relTot > 0.0010 && m[i].fill > 0.035

            m[i].score = score
            m[i].keep = principale || pianoBasso || torretta || spalletta || copertura
            if torretta {
                m[i].tipo = .torretta
            } else if spalletta && !principale {
                m[i].tipo = .spalletta
            } else if m[i].orizzontale {
                m[i].tipo = .orizzontale
            } else {
                m[i].tipo = .facciata
            }
        }

        var ordinati = m.filter(\.keep).sorted {
            if abs($0.score - $1.score) > 0.001 { return $0.score > $1.score }
            return $0.area > $1.area
        }
        if ordinati.count < min(6, m.count) {
            ordinati = Array(m.sorted { $0.area > $1.area }.prefix(min(6, m.count)))
        }

        let maxTotale = 18
        let maxPerAsseVerticale = 4
        let maxNonVerticali = 3
        var countAsse: [Int: Int] = [:]
        var countNonVerticali = 0
        var keepIds = Set<Int>()
        var tipi: [Int: TipoFaccia] = [:]
        var priorita: [Int: Int] = [:]

        for item in ordinati {
            if keepIds.count >= maxTotale { break }
            if item.verticale {
                let c = countAsse[item.asse, default: 0]
                guard c < maxPerAsseVerticale || principaliIds.contains(item.id) else { continue }
                countAsse[item.asse] = c + 1
            } else {
                guard countNonVerticali < maxNonVerticali else { continue }
                countNonVerticali += 1
            }
            keepIds.insert(item.id)
            tipi[item.id] = item.tipo
            priorita[item.id] = max(0, Int(item.score.rounded()))
        }

        guard !keepIds.isEmpty else { return }
        facce = facce.filter { keepIds.contains($0.id) }
        for i in facce.indices {
            if let t = tipi[facce[i].id] { facce[i].tipo = t }
            if let p = priorita[facce[i].id] { facce[i].priorita = p }
        }
    }

    // MARK: Editor poligonale (Fase B): poligono editabile + area metrica

    /// Genera il poligono editabile iniziale = rettangolo orientato del piano nel
    /// suo riferimento (assi `right`/`up` derivati da normale e gravità).
    func generaPoligono(perFaccia id: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              let p = facce[i].pianoPunto, let n0 = facce[i].pianoNormale,
              !facce[i].triangoli.isEmpty else { return }
        let triangoliValidi = facce[i].triangoli.filter {
            mesh.triangles.indices.contains($0)
        }
        guard !triangoliValidi.isEmpty else {
            facce[i].triangoli = []
            facce[i].poligono = []
            return
        }
        facce[i].triangoli = Set(triangoliValidi)
        let n = simd_normalize(n0)
        var right = simd_cross(gravitaSu, n)
        if simd_length(right) < 1e-5 { right = simd_cross(SIMD3(1, 0, 0), n) }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(n, right))
        var xs: [Float] = [], ys: [Float] = []
        xs.reserveCapacity(triangoliValidi.count * 3)
        ys.reserveCapacity(triangoliValidi.count * 3)
        for t in triangoliValidi {
            let tri = mesh.triangles[t]
            for v in [mesh.vertices[Int(tri.x)], mesh.vertices[Int(tri.y)], mesh.vertices[Int(tri.z)]] {
                xs.append(simd_dot(v - p, right)); ys.append(simd_dot(v - p, up))
            }
        }
        guard xs.count >= 3 else { return }
        xs.sort(); ys.sort()
        // Percentili anziché min/max assoluto: scarta il bordo sfrangiato dell'OC e
        // qualche triangolo isolato, così il rettangolo non sborda dalla geometria.
        func perc(_ a: [Float], _ f: Float) -> Float {
            a[min(a.count - 1, max(0, Int((Float(a.count - 1) * f).rounded())))]
        }
        let minx = perc(xs, 0.01), maxx = perc(xs, 0.99)
        let miny = perc(ys, 0.01), maxy = perc(ys, 0.99)
        func pt(_ x: Float, _ y: Float) -> SIMD3<Float> { p + right * x + up * y }
        facce[i].poligono = [pt(minx, miny), pt(maxx, miny), pt(maxx, maxy), pt(minx, maxy)]
    }

    private func generaPoligoniTutti() { for f in facce { generaPoligono(perFaccia: f.id) } }

    /// Piano (punto, normale) della faccia, per il trascinamento delle maniglie.
    func pianoFaccia(_ id: Int) -> (p: SIMD3<Float>, n: SIMD3<Float>)? {
        guard let f = facce.first(where: { $0.id == id }),
              let p = f.pianoPunto, let n = f.pianoNormale else { return nil }
        return (p, simd_normalize(n))
    }

    /// Poligono corrente della faccia (per catturare l'origine del trascinamento).
    func poligonoDi(_ id: Int) -> [SIMD3<Float>]? { facce.first(where: { $0.id == id })?.poligono }

    // MARK: - Allinea: selezione sub-elementi + allineamento agli assi

    /// Posizione 3D del vertice k del poligono della faccia.
    func posizioneVertice(faccia id: Int, k: Int) -> SIMD3<Float>? {
        guard let p = facce.first(where: { $0.id == id })?.poligono, k >= 0, k < p.count else { return nil }
        return p[k]
    }

    private func aggiornaNumElementi() {
        numElementiSel = selVertici.count + selSpigoli.count + selFacceAllinea.count
    }

    func toggleVerticeAllinea(faccia: Int, k: Int) {
        let e = ElemId(faccia: faccia, k: k)
        if selVertici.contains(e) { selVertici.remove(e) } else { selVertici.insert(e) }
        aggiornaNumElementi(); ridisegnaPiani()
    }
    func toggleSpigoloAllinea(faccia: Int, k: Int) {
        let e = ElemId(faccia: faccia, k: k)
        if selSpigoli.contains(e) { selSpigoli.remove(e) } else { selSpigoli.insert(e) }
        aggiornaNumElementi(); ridisegnaPiani()
    }
    func toggleFacciaAllinea(_ id: Int) {
        if selFacceAllinea.contains(id) { selFacceAllinea.remove(id) } else { selFacceAllinea.insert(id) }
        aggiornaNumElementi(); ridisegnaPiani()
    }
    func deselezionaAllinea() {
        selVertici.removeAll(); selSpigoli.removeAll(); selFacceAllinea.removeAll()
        attendoSorgenteAllinea = false
        aggiornaNumElementi(); ridisegnaPiani()
    }
    /// Aggiunge alla selezione (da rettangolo/lazo) senza azzerare l'esistente.
    func aggiungiSelezioneAllinea(vertici: [ElemId], spigoli: [ElemId], facce ids: [Int]) {
        selVertici.formUnion(vertici); selSpigoli.formUnion(spigoli); selFacceAllinea.formUnion(ids)
        aggiornaNumElementi(); ridisegnaPiani()
    }

    /// True se quel vertice è coinvolto dalla selezione corrente (per evidenziarlo).
    func verticeEvidenziato(faccia: Int, k: Int) -> Bool {
        if selVertici.contains(ElemId(faccia: faccia, k: k)) { return true }
        if selFacceAllinea.contains(faccia) { return true }
        if let poly = facce.first(where: { $0.id == faccia })?.poligono {
            for e in selSpigoli where e.faccia == faccia {
                if e.k == k || (e.k + 1) % poly.count == k { return true }
            }
        }
        return false
    }
    func spigoloEvidenziato(faccia: Int, k: Int) -> Bool { selSpigoli.contains(ElemId(faccia: faccia, k: k)) }
    func facciaAllineaSelezionata(_ id: Int) -> Bool { selFacceAllinea.contains(id) }

    /// I tre assi di allineamento (ortonormali) secondo il riferimento scelto.
    private func assiAllinea() -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        switch rifAssiAllinea {
        case .mondo:    return (SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1))
        case .edificio: return (simd_normalize(assiNav.r), simd_normalize(assiNav.u), simd_normalize(assiNav.n))
        }
    }

    /// Vertici (faccia,k) coinvolti dalla selezione corrente, espandendo spigoli e facce.
    private func verticiCoinvolti() -> Set<ElemId> {
        var out = selVertici
        for e in selSpigoli {
            guard let poly = facce.first(where: { $0.id == e.faccia })?.poligono, !poly.isEmpty else { continue }
            out.insert(ElemId(faccia: e.faccia, k: e.k))
            out.insert(ElemId(faccia: e.faccia, k: (e.k + 1) % poly.count))
        }
        for id in selFacceAllinea {
            guard let poly = facce.first(where: { $0.id == id })?.poligono else { continue }
            for k in poly.indices { out.insert(ElemId(faccia: id, k: k)) }
        }
        return out
    }

    /// Allinea i vertici selezionati al PUNTO SORGENTE `p`: per ogni asse attivo,
    /// la coordinata lungo quell'asse viene posta uguale a quella del sorgente
    /// (copia-coordinata). Gli assi non attivi restano invariati.
    func allineaConSorgente(_ p: SIMD3<Float>) {
        let coinvolti = verticiCoinvolti()
        guard !coinvolti.isEmpty else { attendoSorgenteAllinea = false; return }
        let (e0, e1, e2) = assiAllinea()
        var assi: [SIMD3<Float>] = []
        if allineaAsse0 { assi.append(e0) }
        if allineaAsse1 { assi.append(e1) }
        if allineaAsse2 { assi.append(e2) }
        guard !assi.isEmpty else { attendoSorgenteAllinea = false; return }
        registraUndo()
        // raggruppa per faccia
        var perFaccia: [Int: [Int]] = [:]
        for e in coinvolti { perFaccia[e.faccia, default: []].append(e.k) }
        for (id, ks) in perFaccia {
            guard let i = facce.firstIndex(where: { $0.id == id }), var poly = facce[i].poligono else { continue }
            for k in ks where k >= 0 && k < poly.count {
                var v = poly[k]
                for e in assi { v += (simd_dot(p, e) - simd_dot(v, e)) * e }   // coord asse = sorgente
                poly[k] = v
            }
            facce[i].poligono = poly
            // ricalcola piano (Newell) per coerenza con poligono spostato
            if poly.count >= 3 {
                var nrm = SIMD3<Float>(0,0,0)
                for j in poly.indices {
                    let a = poly[j], b = poly[(j+1) % poly.count]
                    nrm.x += (a.y - b.y) * (a.z + b.z)
                    nrm.y += (a.z - b.z) * (a.x + b.x)
                    nrm.z += (a.x - b.x) * (a.y + b.y)
                }
                if simd_length(nrm) > 1e-6 { facce[i].pianoNormale = simd_normalize(nrm) }
                facce[i].pianoPunto = poly.reduce(SIMD3<Float>(0,0,0), +) / Float(poly.count)
            }
        }
        attendoSorgenteAllinea = false
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Ricalcola normale (Newell) e punto del piano dopo aver spostato il poligono.
    private func ricalcolaPianoDaPoligono(_ i: Int) {
        guard let poly = facce[i].poligono, poly.count >= 3 else { return }
        var nrm = SIMD3<Float>(0,0,0)
        for j in poly.indices {
            let a = poly[j], b = poly[(j+1) % poly.count]
            nrm.x += (a.y - b.y) * (a.z + b.z)
            nrm.y += (a.z - b.z) * (a.x + b.x)
            nrm.z += (a.x - b.x) * (a.y + b.y)
        }
        if simd_length(nrm) > 1e-6 { facce[i].pianoNormale = simd_normalize(nrm) }
        facce[i].pianoPunto = poly.reduce(SIMD3<Float>(0,0,0), +) / Float(poly.count)
    }

    /// Centroide 3D dei vertici coinvolti dalla selezione (per il piano di drag).
    func centroideSelezioneAllinea() -> SIMD3<Float>? {
        let vs = verticiCoinvolti()
        var c = SIMD3<Float>(0,0,0); var n = 0
        for e in vs { if let p = posizioneVertice(faccia: e.faccia, k: e.k) { c += p; n += 1 } }
        return n > 0 ? c / Float(n) : nil
    }

    /// Vincola un delta agli assi attivi (nessuno attivo → libero nel piano vista).
    func vincolaDeltaAllinea(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let (e0, e1, e2) = assiAllinea()
        var assi: [SIMD3<Float>] = []
        if allineaAsse0 { assi.append(e0) }
        if allineaAsse1 { assi.append(e1) }
        if allineaAsse2 { assi.append(e2) }
        guard !assi.isEmpty else { return d }
        var out = SIMD3<Float>(0,0,0)
        for e in assi { out += simd_dot(d, e) * e }
        return out
    }

    func iniziaSpostamentoAllinea() { if numElementiSel > 0 { registraUndo() } }

    /// Trasla i vertici coinvolti di `delta` (incrementale durante il drag).
    func spostaSelezioneAllinea(delta: SIMD3<Float>) {
        guard simd_length(delta) > 0 else { return }
        let coinvolti = verticiCoinvolti()
        guard !coinvolti.isEmpty else { return }
        var perFaccia: [Int: [Int]] = [:]
        for e in coinvolti { perFaccia[e.faccia, default: []].append(e.k) }
        for (id, ks) in perFaccia {
            guard let i = facce.firstIndex(where: { $0.id == id }), var poly = facce[i].poligono else { continue }
            for k in ks where k >= 0 && k < poly.count { poly[k] += delta }
            facce[i].poligono = poly
            ricalcolaPianoDaPoligono(i)
        }
        ridisegnaFacce(); ridisegnaPiani()
    }

    func ciclaAsseMovimentoPoligono() {
        switch asseMovimentoPoligono {
        case .libero: asseMovimentoPoligono = .x
        case .x: asseMovimentoPoligono = .y
        case .y: asseMovimentoPoligono = .z
        case .z: asseMovimentoPoligono = .libero
        }
        cursoreInfo = "Movimento: \(asseMovimentoPoligono.etichetta)"
        ridisegnaPiani()
    }

    func assiMovimentoPoligono(faccia id: Int?) -> (r: SIMD3<Float>, u: SIMD3<Float>, n: SIMD3<Float>) {
        let su = simd_normalize(gravitaSu)
        if let id,
           let f = facce.first(where: { $0.id == id }),
           let n0 = f.pianoNormale {
            let n = simd_normalize(n0)
            var r = simd_cross(su, n)
            if simd_length(r) < 1e-4 { r = assiNav.r }
            r = simd_normalize(r)
            let u = simd_normalize(simd_cross(n, r))
            return (r, u, n)
        }
        calcolaAssiNavigazione()
        return assiNav
    }

    func vettoreAsseMovimento(faccia id: Int? = nil) -> SIMD3<Float>? {
        let a = assiMovimentoPoligono(faccia: id)
        switch asseMovimentoPoligono {
        case .libero: return nil
        case .x: return a.r
        case .y: return a.u
        case .z: return a.n
        }
    }

    func selezionaManigliaPoligono(faccia id: Int, edge: Bool, indice: Int) {
        manigliaPoligonoAttiva = ManigliaPoligonoAttiva(faccia: id, edge: edge, indice: indice)
        facciaAttivaId = id
        mostraPiani = true
        ridisegnaPiani()
    }

    /// Fase C — Sposta un intero edge `k` (vertici k e k+1) del poligono, sul piano,
    /// con snap di entrambi gli estremi (Fase D). Per "allungare" il poligono.
    func spostaEdgePoligono(faccia id: Int, edge k: Int, a p0: SIMD3<Float>, _ p1: SIMD3<Float>, snap: Bool = true) {
        guard let i = facce.firstIndex(where: { $0.id == id }), var poly = facce[i].poligono,
              let n = facce[i].pianoNormale, let pp = facce[i].pianoPunto, k >= 0, k < poly.count else { return }
        let nn = simd_normalize(n)
        let k1 = (k + 1) % poly.count
        func proj(_ q: SIMD3<Float>) -> SIMD3<Float> { q - simd_dot(q - pp, nn) * nn }
        var a = proj(p0), b = proj(p1)
        if snap {
            if let ag = agganciaVertice(a, escludi: id, normalePiano: nn) { a = ag }
            if let bg = agganciaVertice(b, escludi: id, normalePiano: nn) { b = bg }
        }
        poly[k] = a; poly[k1] = b
        facce[i].poligono = poly
        ridisegnaPiani()
    }

    /// Splitta l'edge `k`: inserisce un vertice al suo punto medio (da quad a poligono).
    func splittaEdge(faccia id: Int, edge k: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }), var poly = facce[i].poligono,
              k >= 0, k < poly.count else { return }
        registraUndo()
        let k1 = (k + 1) % poly.count
        poly.insert((poly[k] + poly[k1]) * 0.5, at: k1)
        facce[i].poligono = poly
        ridisegnaPiani()
    }

    /// Aggancia l'edge più vicino del poligono attivo alla retta d'intersezione con
    /// la facciata di riferimento (la faccia più estesa con normale non parallela):
    /// spigolo condiviso esatto, senza trascinare a mano (es. spalletta↔facciata).
    func allineaAllaFacciata(_ id: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }), var poly = facce[i].poligono,
              let nA0 = facce[i].pianoNormale, let pA = facce[i].pianoPunto, poly.count >= 2 else { return }
        let nA = simd_normalize(nA0)
        var rifN: SIMD3<Float>? = nil; var rifP = SIMD3<Float>(0, 0, 0); var areaMax: Float = 0
        for f in facce where f.id != id {
            guard let nB0 = f.pianoNormale, let pB = f.pianoPunto else { continue }
            if abs(simd_dot(simd_normalize(nB0), nA)) > 0.9 { continue }   // troppo parallela
            let a = mesh.areaTriangoli(f.triangoli)
            if a > areaMax { areaMax = a; rifN = simd_normalize(nB0); rifP = pB }
        }
        guard let nB = rifN else { return }
        let dir = simd_cross(nA, nB)
        guard simd_length(dir) > 1e-3 else { return }
        let u = simd_normalize(dir)
        guard let pL = puntoSuRetta(nA: nA, pA: pA, nB: nB, pB: rifP, dir: u) else { return }
        func suRetta(_ q: SIMD3<Float>) -> SIMD3<Float> { pL + u * simd_dot(q - pL, u) }
        var bestK = 0; var bestD = Float.greatestFiniteMagnitude
        for k in poly.indices {
            let mid = (poly[k] + poly[(k + 1) % poly.count]) * 0.5
            let d = simd_length(suRetta(mid) - mid)
            if d < bestD { bestD = d; bestK = k }
        }
        registraUndo()
        let k1 = (bestK + 1) % poly.count
        poly[bestK] = suRetta(poly[bestK]); poly[k1] = suRetta(poly[k1])
        facce[i].poligono = poly
        ridisegnaPiani()
    }

    func creaSpallaDaPianiSelezionati() {
        let ids = Array(Set(bersagli))
        guard ids.count >= 2,
              let aId = ids.first,
              let bId = ids.dropFirst().first,
              let ia = facce.firstIndex(where: { $0.id == aId }),
              let ib = facce.firstIndex(where: { $0.id == bId }) else { return }
        if facce[ia].poligono == nil { generaPoligono(perFaccia: aId) }
        if facce[ib].poligono == nil { generaPoligono(perFaccia: bId) }
        guard let pa = facce.first(where: { $0.id == aId })?.poligono, pa.count >= 2,
              let pb = facce.first(where: { $0.id == bId })?.poligono, pb.count >= 2 else { return }

        func edge(_ poly: [SIMD3<Float>], _ k: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            (poly[k], poly[(k + 1) % poly.count])
        }
        func score(_ a0: SIMD3<Float>, _ a1: SIMD3<Float>, _ b0: SIMD3<Float>, _ b1: SIMD3<Float>) -> (Float, Bool) {
            let sDiretto = simd_length(a0 - b0) + simd_length(a1 - b1)
            let sInvertito = simd_length(a0 - b1) + simd_length(a1 - b0)
            return sDiretto <= sInvertito ? (sDiretto, false) : (sInvertito, true)
        }

        var best: (Float, Int, Int, Bool)? = nil
        for ka in pa.indices {
            let ea = edge(pa, ka)
            for kb in pb.indices {
                let eb = edge(pb, kb)
                let s = score(ea.0, ea.1, eb.0, eb.1)
                if best == nil || s.0 < best!.0 { best = (s.0, ka, kb, s.1) }
            }
        }
        guard let match = best else { return }
        let ea = edge(pa, match.1)
        let eb = edge(pb, match.2)
        let q: [SIMD3<Float>] = match.3 ? [ea.0, ea.1, eb.0, eb.1] : [ea.0, ea.1, eb.1, eb.0]
        let nRaw = simd_cross(q[1] - q[0], q[2] - q[0])
        guard simd_length(nRaw) > 1e-6 else { return }
        let n = simd_normalize(nRaw)
        let p = q.reduce(SIMD3<Float>(0, 0, 0), +) / Float(q.count)

        registraUndo()
        let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
        var f = FacciaProxy(id: prossimoIdFaccia, nome: "Spalla \(prossimoIdFaccia)", colore: colore)
        prossimoIdFaccia += 1
        f.tipo = .spalletta
        f.pianoPunto = p
        f.pianoNormale = n
        f.poligono = q
        facce.append(f)
        facciaAttivaId = f.id
        facceSelezionate = [f.id]
        pianiGenerati = facce.filter { $0.pianoNormale != nil }.count
        mostraPiani = true
        ridisegnaPiani()
    }

    /// Fase C — Sposta il vertice `k` del poligono della faccia `id` mantenendolo
    /// sul piano. Con `snap` cerca un aggancio (vertice/edge di altri piani, Fase D).
    func spostaVerticePoligono(faccia id: Int, indice k: Int, a posMondo: SIMD3<Float>, snap: Bool = true) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              var poly = facce[i].poligono, k >= 0, k < poly.count,
              let n = facce[i].pianoNormale, let p = facce[i].pianoPunto else { return }
        let nn = simd_normalize(n)
        var pos = posMondo - simd_dot(posMondo - p, nn) * nn   // resta sul piano
        if snap, let ag = agganciaVertice(pos, escludi: id, normalePiano: nn) { pos = ag }
        poly[k] = pos
        facce[i].poligono = poly
        ridisegnaPiani()
    }

    /// Fase D — Aggancio: prima ai vertici degli altri poligoni vicini, poi alla
    /// retta d'intersezione fra il piano corrente e quello del poligono vicino
    /// (spigolo condiviso, es. spalletta↔facciata). Ritorna la posizione agganciata.
    private func agganciaVertice(_ pos: SIMD3<Float>, escludi id: Int, normalePiano nA: SIMD3<Float>) -> SIMD3<Float>? {
        let soglia = estensioneMesh * 0.02   // ~2% del lato
        var miglior: SIMD3<Float>? = nil; var minD = soglia
        // 1) snap vertice→vertice
        for f in facce where f.id != id {
            for v in f.poligono ?? [] {
                let d = simd_length(v - pos)
                if d < minD { minD = d; miglior = v }
            }
        }
        if let m = miglior { return m }
        // 2) snap alla retta d'intersezione dei due piani (spigolo condiviso)
        for f in facce where f.id != id {
            guard let nB0 = f.pianoNormale, let pB = f.pianoPunto else { continue }
            let nB = simd_normalize(nB0)
            let dir = simd_cross(nA, nB)
            if simd_length(dir) < 1e-3 { continue }       // piani paralleli: nessuna retta
            let u = simd_normalize(dir)
            // un punto della retta: risolve il sistema dei due piani (minima norma)
            guard let pL = puntoSuRetta(nA: nA, pA: pos, nB: nB, pB: pB, dir: u) else { continue }
            let proj = pL + u * simd_dot(pos - pL, u)       // proiezione di pos sulla retta
            let d = simd_length(proj - pos)
            if d < minD { minD = d; miglior = proj }
        }
        return miglior
    }

    /// Un punto della retta d'intersezione dei piani A(nA,pA) e B(nB,pB) con
    /// direzione `dir`: risolve i due vincoli planari nel piano ⟂ a dir.
    private func puntoSuRetta(nA: SIMD3<Float>, pA: SIMD3<Float>,
                              nB: SIMD3<Float>, pB: SIMD3<Float>, dir: SIMD3<Float>) -> SIMD3<Float>? {
        let dA = simd_dot(nA, pA), dB = simd_dot(nB, pB)
        // base nel piano ⟂ a dir
        let e1 = simd_normalize(nA)
        let e2 = simd_normalize(simd_cross(dir, e1))
        // x = a*e1 + b*e2 ; nA·x = dA ; nB·x = dB
        let m00 = simd_dot(nA, e1), m01 = simd_dot(nA, e2)
        let m10 = simd_dot(nB, e1), m11 = simd_dot(nB, e2)
        let det = m00 * m11 - m01 * m10
        if abs(det) < 1e-6 { return nil }
        let a = (dA * m11 - m01 * dB) / det
        let b = (m00 * dB - dA * m10) / det
        return e1 * a + e2 * b
    }

    /// Area del poligono editabile, in unità mesh (shoelace 3D sul piano). Per i m²
    /// metrici va moltiplicata per il quadrato della scala mesh→metri.
    func areaPoligono(_ f: FacciaProxy) -> Float? {
        guard let poly = f.poligono, poly.count >= 3, let n = f.pianoNormale else { return nil }
        var s = SIMD3<Float>(0, 0, 0)
        for k in poly.indices {
            let a = poly[k], b = poly[(k + 1) % poly.count]
            s += simd_cross(a, b)
        }
        return abs(simd_dot(s, simd_normalize(n))) * 0.5
    }

    // MARK: Fase A — semina rettangolare

    /// Cresce UN piano dal seme dato; ritorna l'id della faccia creata (o nil).
    @discardableResult
    private func creaPianoDa(seme: Set<Int>, adiacenza adj: EditableMesh.Adiacenza? = nil) -> Int? {
        guard let (p, n) = mesh.fitPianoRANSAC(seme) else { return nil }
        let tol = Float(tolleranzaNormaleGradi)
        let cresciuto = mesh.crescePianare(da: seme, normale: n, punto: p, tolGradi: tol, adiacenza: adj ?? adiacenza())
        let (p2, n2) = mesh.fitPianoRANSAC(cresciuto) ?? (p, n)
        for j in facce.indices { facce[j].triangoli.subtract(cresciuto) }
        let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
        var f = FacciaProxy(id: prossimoIdFaccia, nome: "Piano \(prossimoIdFaccia)", colore: colore)
        prossimoIdFaccia += 1
        f.triangoli = cresciuto; f.pianoPunto = p2; f.pianoNormale = n2
        f.erroreRms = mesh.rmsDalPiano(cresciuto, punto: p2, normale: n2)
        facce.append(f)
        return f.id
    }

    /// Aggiunge i triangoli SELEZIONATI al piano attivo (per completare porzioni
    /// che la crescita ha mancato), ne ricalcola il piano e ri-espande il poligono.
    func aggiungiSelezioneAlPianoAttivo() {
        guard !selezione.isEmpty, let id = facciaAttivaId,
              let i = facce.firstIndex(where: { $0.id == id }) else { return }
        registraUndo()
        let nuovi = selezione
        for j in facce.indices where j != i { facce[j].triangoli.subtract(nuovi) }
        facce[i].triangoli.formUnion(nuovi)
        if let (p, n) = mesh.fitPianoRANSAC(facce[i].triangoli) {
            facce[i].pianoPunto = p; facce[i].pianoNormale = n
            facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p, normale: n)
        }
        generaPoligono(perFaccia: id)
        deselezionaTutto()
        mostraProxy = true; mostraPiani = true
        ridisegnaFacce(); ridisegnaPiani()
    }

    // MARK: Flusso rapido — Tocca semi + Cresci tutti

    /// Lascia un seme sul triangolo toccato (un futuro piano). Istantaneo.
    func aggiungiSeme(triangolo i: Int, punto: SIMD3<Float>) {
        guard i >= 0, i < mesh.triangles.count else { return }
        semiTocco.append((i, punto))
        numSemi = semiTocco.count
        ridisegnaSemi()
    }

    /// Rimuove tutti i semi marcati (senza crescere).
    func annullaSemi() {
        semiTocco.removeAll(); numSemi = 0; ridisegnaSemi()
    }

    /// Fa crescere TUTTI i semi in una passata (adiacenza condivisa = veloce),
    /// creando un piano per ciascuno.
    func cresciTuttiSemi() {
        guard !semiTocco.isEmpty else { return }
        registraUndo()
        let adj = adiacenza()
        var ultimo: Int? = nil
        for s in semiTocco {
            if facce.contains(where: { $0.triangoli.contains(s.tri) }) { continue } // già coperto
            if let id = creaPianoDa(seme: [s.tri], adiacenza: adj) { ultimo = id }
        }
        facce.removeAll { $0.triangoli.isEmpty }
        stimaGravita()
        classificaPerGravita()
        for f in facce { generaPoligono(perFaccia: f.id) }
        if let id = ultimo { facciaAttivaId = id }
        pianiGenerati = facce.count
        mostraProxy = true; mostraPiani = true
        annullaSemi()
        strumento = .facce
        ridisegnaFacce(); ridisegnaPiani()
    }

    private func ridisegnaSemi() {
        semiNode.childNodes.forEach { $0.removeFromParentNode() }
        let r = CGFloat(estensioneMesh) * 0.012
        for s in semiTocco {
            let sf = SCNSphere(radius: r); sf.segmentCount = 12
            let m = SCNMaterial(); m.diffuse.contents = UIColor.systemYellow
            m.lightingModel = .constant; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
            sf.materials = [m]
            let node = SCNNode(geometry: sf)
            node.position = SCNVector3(s.punto.x, s.punto.y, s.punto.z)
            semiNode.addChildNode(node)
        }
    }

    // MARK: Rileva perimetro — slice orizzontale → traccia → estrudi in facciate

    /// Entra in modalità perimetro: calcola lo slice e mette la vista dall'alto.
    /// Fase 1: posiziona la sezione sul 3D (slider quota). Fase 2: traccia il
    /// bordo nel pannello 2D.
    func avviaPerimetro() {
        modoPerimetro = true
        perimetroTraccia = false   // si parte posizionando la sezione sul 3D
        strumento = .orbita        // pan = orbita; la mesh resta visibile
        puntiPerimetro = []; numPuntiPerimetro = 0
        anelliPerimetro = []; numAnelliPerimetro = 0
        mostraMesh = true          // assicura la geometria visibile
        aggiornaSlice()
    }

    /// Passa alla fase di tracciamento (apre il pannello 2D).
    func iniziaTraccia() { perimetroTraccia = true; aggiornaSlice() }

    /// Esce dalla modalità perimetro: pulisce e riporta la vista in fronte (così la
    /// geometria è sempre visibile, mai "di taglio").
    func esciPerimetro() {
        modoPerimetro = false
        perimetroTraccia = false
        strumento = .orbita
        puntiPerimetro = []; numPuntiPerimetro = 0
        anelliPerimetro = []; numAnelliPerimetro = 0
        perimetroNode.childNodes.forEach { $0.removeFromParentNode() }
        mostraMesh = true
        // NESSUN cambio camera: resta dove l'hai lasciata → la mesh non sparisce.
    }

    /// Vista dall'alto on-demand per posizionare/vedere la sezione.
    func vistaDallAlto() { snapAlto() }

    /// Piano di slice corrente (punto, normale) — per il raycast dei tap.
    func pianoSlice() -> (p: SIMD3<Float>, n: SIMD3<Float>) {
        let su = simd_normalize(gravitaSu)
        return (su * sliceS0, su)
    }

    /// Ricalcola lo slice alla quota corrente e aggiorna pannello 2D + overlay 3D.
    func aggiornaSlice() {
        guard modoPerimetro else { return }
        let su = simd_normalize(gravitaSu)
        // base orizzontale stabile del piano di slice
        var e1 = simd_cross(su, SIMD3<Float>(0, 0, 1))
        if simd_length(e1) < 1e-4 { e1 = simd_cross(su, SIMD3<Float>(1, 0, 0)) }
        perimE1 = simd_normalize(e1); perimE2 = simd_normalize(simd_cross(su, perimE1))
        let (sMin, sMax) = mesh.rangeLungo(su)
        sliceS0 = sMin + max(0, min(1, quotaSlice)) * (sMax - sMin)
        let segs = mesh.sezione(quota: sliceS0, normale: su)
        ultimaSezione = segs
        angoliSlice = angoliDaSezione(segs)   // spigoli del profilo per lo snap
        ridisegnaPerimetro(segs)         // overlay 3D
        aggiornaDisegno2D(segs)          // pannello 2D
    }

    /// #2 — Trova automaticamente gli ANGOLI del profilo: concatena i segmenti
    /// della sezione in una polilinea ordinata, poi semplifica (Douglas-Peucker)
    /// → pochi punti sugli spigoli, già pronti per l'estrusione.
    func autoPerimetro() {
        let semplici = angoliDaSezione(ultimaSezione)
        guard semplici.count >= 2 else { return }
        puntiPerimetro = semplici; numPuntiPerimetro = semplici.count
        aggiornaSlice()
    }

    /// Concatena i segmenti della sezione in una polilinea ordinata (greedy: a
    /// ogni passo prosegue nel verso più dritto). Base per auto-angoli e snap.
    private func contornoOrdinato(_ segs: [(SIMD3<Float>, SIMD3<Float>)]) -> [SIMD3<Float>] {
        guard !segs.isEmpty else { return [] }
        let eps = max(estensioneMesh * 1e-3, 1e-6)
        let inv = 1.0 / eps
        func chiave(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x * inv).rounded()), Int32((p.y * inv).rounded()), Int32((p.z * inv).rounded()))
        }
        var nodeOf = [SIMD3<Int32>: Int](); var pos: [SIMD3<Float>] = []
        func nodeId(_ p: SIMD3<Float>) -> Int {
            let k = chiave(p)
            if let id = nodeOf[k] { return id }
            let id = pos.count; nodeOf[k] = id; pos.append(p); return id
        }
        var edges: [(Int, Int)] = []
        for (a, b) in segs { let ia = nodeId(a), ib = nodeId(b); if ia != ib { edges.append((ia, ib)) } }
        var incident = [[Int]](repeating: [], count: pos.count)
        for (ei, e) in edges.enumerated() { incident[e.0].append(ei); incident[e.1].append(ei) }
        // parti da un capo aperto (grado 1) se c'è, altrimenti dal nodo 0
        var start = 0
        for n in 0..<pos.count where incident[n].count == 1 { start = n; break }
        var usate = Set<Int>(); var path = [start]; var cur = start
        var prevDir: SIMD3<Float>? = nil
        while true {
            var best = -1; var bestScore: Float = -2
            for ei in incident[cur] where !usate.contains(ei) {
                let e = edges[ei]; let nxt = e.0 == cur ? e.1 : e.0
                let dir = simd_normalize(pos[nxt] - pos[cur])
                let score = prevDir == nil ? 1 : simd_dot(prevDir!, dir)
                if score > bestScore { bestScore = score; best = ei }
            }
            if best < 0 { break }
            usate.insert(best)
            let e = edges[best]; let nxt = e.0 == cur ? e.1 : e.0
            if nxt == start { break }
            prevDir = simd_normalize(pos[nxt] - pos[cur])
            path.append(nxt); cur = nxt
        }
        return path.map { pos[$0] }
    }

    /// Spigoli del profilo. Il contorno viene semplificato e poi spezzato nei
    /// MURI (tratti dritti lunghi); lo spigolo è l'INCROCIO delle rette di due muri
    /// consecutivi → corretto anche sugli angoli SMUSSATI/arrotondati (il punto non
    /// finisce sullo smusso). `sensibilitaAngoli` regola quanti spigoli emergono.
    private func angoliDaSezione(_ segs: [(SIMD3<Float>, SIMD3<Float>)]) -> [SIMD3<Float>] {
        let pts = contornoOrdinato(segs)
        guard pts.count >= 2 else { return pts }
        let s = max(0, min(1, sensibilitaAngoli))
        // sensibilità alta = più dettaglio → eps e lunghezza-min muro più piccole
        let eps = estensioneMesh * (0.004 + (1 - s) * 0.03)
        let minMuro = estensioneMesh * (0.02 + (1 - s) * 0.14)
        let dp = douglasPeucker(pts, eps: eps)
        guard dp.count >= 3 else { return dp }

        // chiuso se il profilo torna su sé stesso
        let chiuso = simd_length(dp.first! - dp.last!) < estensioneMesh * 0.02
        var poly = dp
        if chiuso, poly.count > 1 { poly.removeLast() }   // togli il doppione di chiusura
        let n = poly.count
        guard n >= 3 else { return dp }

        // lati come rette in (u,v); tieni solo i MURI (lati lunghi)
        struct Retta { let p: CGPoint; let d: CGPoint; let muro: Bool }
        var rette: [Retta] = []
        let nLati = chiuso ? n : n - 1
        for i in 0..<nLati {
            let a = uv(poly[i]), b = uv(poly[(i + 1) % n])
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            guard len > 1e-6 else { continue }
            rette.append(Retta(p: a, d: CGPoint(x: dx / len, y: dy / len),
                               muro: Float(len) >= minMuro))
        }
        let muri = rette.filter { $0.muro }
        // pochi muri → fallback ai vertici semplificati
        guard muri.count >= 2 else { return dp }

        func incrocio(_ r1: Retta, _ r2: Retta) -> CGPoint? {
            let den = r1.d.x * r2.d.y - r1.d.y * r2.d.x
            if abs(den) < 1e-6 { return nil }   // paralleli
            let dx = r2.p.x - r1.p.x, dy = r2.p.y - r1.p.y
            let t = (dx * r2.d.y - dy * r2.d.x) / den
            return CGPoint(x: r1.p.x + t * r1.d.x, y: r1.p.y + t * r1.d.y)
        }
        var out: [SIMD3<Float>] = []
        let m = muri.count
        let coppie = chiuso ? m : m - 1
        for i in 0..<coppie {
            if let c = incrocio(muri[i], muri[(i + 1) % m]) { out.append(mondoDaUV(c)) }
        }
        return out.count >= 2 ? out : dp
    }

    private func douglasPeucker(_ pts: [SIMD3<Float>], eps: Float) -> [SIMD3<Float>] {
        guard pts.count > 2, let a = pts.first, let b = pts.last else { return pts }
        let ab = b - a; let len = simd_length(ab)
        var maxD: Float = 0; var idx = 0
        for i in 1..<(pts.count - 1) {
            let d = len < 1e-6 ? simd_length(pts[i] - a) : simd_length(simd_cross(pts[i] - a, ab)) / len
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > eps {
            let left = douglasPeucker(Array(pts[0...idx]), eps: eps)
            let right = douglasPeucker(Array(pts[idx...]), eps: eps)
            return Array(left.dropLast()) + right
        }
        return [a, b]
    }

    /// (u,v) nel piano di slice da un punto 3D, e viceversa.
    private func uv(_ p: SIMD3<Float>) -> CGPoint {
        CGPoint(x: CGFloat(simd_dot(p, perimE1)), y: CGFloat(simd_dot(p, perimE2)))
    }
    func mondoDaUV(_ p: CGPoint) -> SIMD3<Float> {
        simd_normalize(gravitaSu) * sliceS0 + perimE1 * Float(p.x) + perimE2 * Float(p.y)
    }

    /// Aggancia una coord (u,v) allo SPIGOLO del profilo più vicino entro `raggioUV`;
    /// se nessuno è abbastanza vicino, lascia il punto dov'è. Ritorna il punto 3D.
    private func snapUVaAngolo(_ p: CGPoint, raggioUV: CGFloat) -> SIMD3<Float> {
        guard snapPerimetroAttivo else { return mondoDaUV(p) }   // snap disattivato
        var best: SIMD3<Float>? = nil
        var bestD = raggioUV
        for a in angoliSlice {
            let q = uv(a)
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestD { bestD = d; best = a }
        }
        return best ?? mondoDaUV(p)
    }

    /// Indice del punto del perimetro più vicino a (u,v) entro `raggioUV`, se c'è.
    func indicePuntoPerimetro(vicinoUV p: CGPoint, raggioUV: CGFloat) -> Int? {
        var best: Int? = nil
        var bestD = raggioUV
        for (i, q) in puntiPerimetro.map({ uv($0) }).enumerated() {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// Aggiunge un punto del perimetro dal pannello 2D, agganciandolo allo spigolo
    /// più vicino entro `raggioSnapUV`.
    func toccaUV(_ p: CGPoint, raggioSnapUV: CGFloat = 0) {
        aggiungiPuntoPerimetro(snapUVaAngolo(p, raggioUV: raggioSnapUV))
    }

    /// Sposta un punto già inserito (drag dal pannello 2D), con snap agli spigoli.
    /// Usa il refresh LEGGERO: non ricalcola la sezione → trascinamento fluido.
    func muoviPuntoPerimetro(_ i: Int, aUV p: CGPoint, raggioSnapUV: CGFloat) {
        guard puntiPerimetro.indices.contains(i) else { return }
        puntiPerimetro[i] = snapUVaAngolo(p, raggioUV: raggioSnapUV)
        rinfrescaTraccia()
    }

    /// Ridisegna SOLO la traccia (2D + overlay 3D) riusando la sezione già calcolata.
    /// Niente `mesh.sezione` → adatto al trascinamento continuo.
    private func rinfrescaTraccia() {
        ridisegnaPerimetro(ultimaSezione)
        aggiornaDisegno2D(ultimaSezione)
    }

    private func aggiornaDisegno2D(_ segs: [(SIMD3<Float>, SIMD3<Float>)]) {
        var d = PerimetroDisegno()
        d.segmenti = segs.map { (uv($0.0), uv($0.1)) }
        d.punti = puntiPerimetro.map { uv($0) }
        d.angoli = angoliSlice.map { uv($0) }
        d.anelli = anelliPerimetro.map { $0.map { uv($0) } }
        var traccia = puntiPerimetro
        if chiudiPerimetro, puntiPerimetro.count >= 3, let f = puntiPerimetro.first { traccia.append(f) }
        d.spline = traccia.map { uv($0) }   // linee rette tra i punti (campo riusato)
        // bounds (unione di tutti i punti)
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = maxX
        func acc(_ q: CGPoint) { minX = min(minX, q.x); minY = min(minY, q.y); maxX = max(maxX, q.x); maxY = max(maxY, q.y) }
        for s in d.segmenti { acc(s.0); acc(s.1) }
        for q in d.punti { acc(q) }
        if maxX > minX, maxY > minY {
            d.bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        disegnoPerimetro = d
    }

    /// Aggiunge un punto del perimetro (sul piano di slice).
    func aggiungiPuntoPerimetro(_ punto: SIMD3<Float>) {
        puntiPerimetro.append(punto); numPuntiPerimetro = puntiPerimetro.count
        rinfrescaTraccia()   // la sezione non cambia coi punti → refresh leggero
    }

    func annullaUltimoPuntoPerimetro() {
        guard !puntiPerimetro.isEmpty else { return }
        puntiPerimetro.removeLast(); numPuntiPerimetro = puntiPerimetro.count
        rinfrescaTraccia()
    }

    /// Estrude il perimetro tracciato: ogni lato → un piano verticale di facciata
    /// (poligono che va dal fondo alla cima dell'edificio lungo la gravità).
    func estrudiPerimetro() {
        guard puntiPerimetro.count >= 2 else { return }
        registraUndo()
        let su = simd_normalize(gravitaSu)
        let (sMin, sMax) = mesh.rangeLungo(su)
        // un lato rettilineo per ogni coppia di punti consecutivi (+ chiusura opzionale)
        var lati: [(SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<(puntiPerimetro.count - 1) { lati.append((puntiPerimetro[i], puntiPerimetro[i + 1])) }
        if chiudiPerimetro, puntiPerimetro.count >= 3, let a = puntiPerimetro.first, let b = puntiPerimetro.last {
            lati.append((b, a))
        }
        for (a, b) in lati {
            let aH = a - simd_dot(a, su) * su, bH = b - simd_dot(b, su) * su   // parte orizzontale
            var nrm = simd_cross(b - a, su)
            if simd_length(nrm) < 1e-5 { continue }
            nrm = simd_normalize(nrm)
            let la = aH + su * sMin, lb = bH + su * sMin
            let hb = bH + su * sMax, ha = aH + su * sMax
            let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
            var f = FacciaProxy(id: prossimoIdFaccia, nome: "Facciata \(prossimoIdFaccia)", colore: colore)
            prossimoIdFaccia += 1
            f.poligono = [la, lb, hb, ha]
            f.pianoNormale = nrm
            f.pianoPunto = (la + lb + hb + ha) * 0.25
            f.tipo = .facciata
            facce.append(f)
            fittaPianoAllaMesh(f.id)   // segui il muro reale (anche inclinato)
        }
        esciPerimetro()
        pianiGenerati = facce.count
        mostraPiani = true
        facciaAttivaId = facce.last?.id
        ridisegnaFacce(); ridisegnaPiani()
    }

    // MARK: Perimetro a più quote → piani inclinati

    /// Salva l'anello corrente (alla sua quota) e prepara il prossimo: il nuovo
    /// anello PARTE COPIANDO quello appena salvato, così gli spigoli corrispondono
    /// 1:1 fra le quote. Sposta lo slider di quota e sistema i punti che cambiano.
    func salvaAnelloPerimetro() {
        guard puntiPerimetro.count >= 2 else { return }
        anelliPerimetro.append(puntiPerimetro)
        numAnelliPerimetro = anelliPerimetro.count
        copiaUltimoAnelloAllaQuota()   // pre-carica il prossimo anello identico
    }

    /// Ricarica l'ultimo anello salvato proiettato alla quota corrente dello slice:
    /// stessi (u,v), nuova altezza. Da usare dopo aver spostato lo slider.
    func copiaUltimoAnelloAllaQuota() {
        guard let ultimo = anelliPerimetro.last else { return }
        puntiPerimetro = ultimo.map { mondoDaUV(uv($0)) }   // uv invariato, quota = sliceS0 corrente
        numPuntiPerimetro = puntiPerimetro.count
        rinfrescaTraccia()
    }

    /// Estrude usando TUTTI gli anelli salvati (≥2): per ogni lato costruisce un
    /// piano che passa per gli spigoli corrispondenti alle varie quote → se gli
    /// spigoli sono spostati fra una quota e l'altra, il piano si INCLINA da solo.
    func estrudiPerimetroInclinato() {
        var anelli = anelliPerimetro
        if puntiPerimetro.count >= 2 { anelli.append(puntiPerimetro) }   // includi quello in corso
        guard anelli.count >= 2 else { estrudiPerimetro(); return }
        let su = simd_normalize(gravitaSu)
        let z = SIMD3<Float>(repeating: 0)
        func quota(_ r: [SIMD3<Float>]) -> Float { simd_dot(r.first ?? z, su) }
        anelli.sort { quota($0) < quota($1) }
        // dedup per quota: scarta anelli alla stessa altezza (es. il duplicato in corso)
        let tolQ = estensioneMesh * 0.01
        var distinti: [[SIMD3<Float>]] = []
        for r in anelli {
            if let last = distinti.last, abs(quota(r) - quota(last)) < tolQ { distinti[distinti.count - 1] = r }
            else { distinti.append(r) }
        }
        anelli = distinti
        guard anelli.count >= 2 else { estrudiPerimetro(); return }
        let nPunti = anelli.map(\.count).min() ?? 0
        guard nPunti >= 2 else { return }
        registraUndo()
        let nLati = chiudiPerimetro ? nPunti : nPunti - 1
        for k in 0..<nLati {
            let k1 = (k + 1) % nPunti
            // bordo del lato: su lungo lo spigolo k attraverso le quote, giù lungo k1
            var loop: [SIMD3<Float>] = []
            for r in anelli { loop.append(r[k]) }
            for r in anelli.reversed() { loop.append(r[k1]) }
            guard loop.count >= 3 else { continue }
            // normale del poligono (Newell) → robusta anche se inclinato
            var nrm = SIMD3<Float>(0, 0, 0)
            for i in loop.indices {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                nrm.x += (a.y - b.y) * (a.z + b.z)
                nrm.y += (a.z - b.z) * (a.x + b.x)
                nrm.z += (a.x - b.x) * (a.y + b.y)
            }
            guard simd_length(nrm) > 1e-6 else { continue }
            nrm = simd_normalize(nrm)
            let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
            var f = FacciaProxy(id: prossimoIdFaccia, nome: "Facciata \(prossimoIdFaccia)", colore: colore)
            prossimoIdFaccia += 1
            f.poligono = loop
            f.pianoNormale = nrm
            f.pianoPunto = loop.reduce(SIMD3<Float>(0, 0, 0), +) / Float(loop.count)
            f.tipo = .facciata
            facce.append(f)
        }
        esciPerimetro()
        pianiGenerati = facce.count
        mostraPiani = true
        facciaAttivaId = facce.last?.id
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Fitta il piano (poligono) alla MESH reale: raccoglie i triangoli vicini al
    /// piano e allineati, ne fa il fit RANSAC e ri-proietta il poligono sul piano
    /// fittato. Così, se il muro è inclinato, il piano lo segue.
    func fittaPianoAllaMesh(_ id: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              let poly0 = facce[i].poligono, let n0 = facce[i].pianoNormale,
              let p0 = facce[i].pianoPunto else { return }
        let n = simd_normalize(n0)
        let (lo, hi) = mesh.aabb
        let ext = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
        let banda = ext * 0.12
        let cosN = cos(50 * Float.pi / 180)

        // 1) Ri-fitta l'ORIENTAMENTO del piano sul muro reale, usando i triangoli
        //    vicini al poligono corrente (clamp orizzontale: non agganciare muri lontani).
        let su0 = simd_normalize(gravitaSu)
        var asseOr = simd_cross(su0, n)
        if simd_length(asseOr) < 1e-5 { asseOr = simd_cross(SIMD3(1, 0, 0), n) }
        asseOr = simd_normalize(asseOr)
        let projO = poly0.map { simd_dot($0 - p0, asseOr) }
        let oMin = (projO.min() ?? 0) - banda, oMax = (projO.max() ?? 0) + banda
        var vicini = Set<Int>()
        for t in mesh.triangles.indices {
            let c = mesh.centroid(mesh.triangles[t])
            guard abs(simd_dot(c - p0, n)) < banda, abs(simd_dot(mesh.normale(t), n)) > cosN else { continue }
            let o = simd_dot(c - p0, asseOr)
            if o >= oMin, o <= oMax { vicini.insert(t) }
        }
        guard vicini.count >= 8, let (pf, nfv) = mesh.fitPianoRANSAC(vicini) else { return }
        var nf = simd_normalize(nfv)
        if simd_dot(nf, n) < 0 { nf = -nf }

        // 2) ESTENSIONE PIENA della facciata. Il poligono NON deve fermarsi dove la
        //    crescita planare si è interrotta (la "cresta" del parapetto): prendiamo
        //    il bbox di TUTTI i triangoli complanari entro una banda perpendicolare,
        //    con tolleranza di normale ampia così includiamo le facce verticali di
        //    parapetti/torrette. Risultato: il piano copre base→colmo dell'edificio.
        let su = simd_normalize(gravitaSu)
        var right = simd_cross(su, nf)
        if simd_length(right) < 1e-5 { right = simd_cross(SIMD3(1, 0, 0), nf) }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(nf, right))
        let cosWide = cos(65 * Float.pi / 180)   // ammette parapetti/torrette leggermente inclinati
        let bandaExt = ext * 0.10                // assorbe spessore muro + parapetto rientrante
        var xs: [Float] = [], ys: [Float] = []
        for t in mesh.triangles.indices {
            let c = mesh.centroid(mesh.triangles[t])
            guard abs(simd_dot(c - pf, nf)) < bandaExt,
                  abs(simd_dot(mesh.normale(t), nf)) > cosWide else { continue }
            xs.append(simd_dot(c - pf, right)); ys.append(simd_dot(c - pf, up))
        }
        guard xs.count >= 8 else { return }
        xs.sort(); ys.sort()
        // percentili robusti: scarta triangoli isolati senza tagliare il parapetto
        func perc(_ a: [Float], _ f: Float) -> Float {
            a[min(a.count - 1, max(0, Int((Float(a.count - 1) * f).rounded())))]
        }
        let minx = perc(xs, 0.004), maxx = perc(xs, 0.996)
        let miny = perc(ys, 0.004), maxy = perc(ys, 0.996)
        guard maxx > minx, maxy > miny else { return }
        func pt(_ x: Float, _ y: Float) -> SIMD3<Float> { pf + right * x + up * y }

        facce[i].pianoNormale = nf
        facce[i].pianoPunto = pf
        facce[i].triangoli = vicini
        facce[i].erroreRms = mesh.rmsDalPiano(vicini, punto: pf, normale: nf)
        facce[i].poligono = [pt(minx, miny), pt(maxx, miny), pt(maxx, maxy), pt(minx, maxy)]
        mostraPiani = true
        ridisegnaPiani()
    }

    /// Spline Catmull-Rom passante per i punti di controllo (chiusa se ≥3 punti):
    /// "ricalca" il profilo con una curva morbida.
    private func splinePunti(perSeg: Int = 12) -> [SIMD3<Float>] {
        let p = puntiPerimetro
        guard p.count >= 3 else { return p }
        let n = p.count
        func cr(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            let t2 = t * t, t3 = t2 * t
            let a: SIMD3<Float> = 2 * p1
            let b: SIMD3<Float> = (p2 - p0) * t
            let c0: SIMD3<Float> = 2 * p0 - 5 * p1 + 4 * p2 - p3
            let c: SIMD3<Float> = c0 * t2
            let d0: SIMD3<Float> = 3 * p1 - 3 * p2 + p3 - p0
            let d: SIMD3<Float> = d0 * t3
            return (a + b + c + d) * 0.5
        }
        var out: [SIMD3<Float>] = []
        for i in 0..<n {   // chiusa
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            for s in 0..<perSeg { out.append(cr(p0, p1, p2, p3, Float(s) / Float(perSeg))) }
        }
        out.append(p[0])
        return out
    }

    /// Semplifica una polilinea in segmenti rettilinei: spezza dove la direzione
    /// cambia oltre `tolGradi` (muri dritti → 1 segmento, curve → più segmenti).
    private func semplificaSegmenti(_ pts: [SIMD3<Float>], tolGradi: Float = 12) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard pts.count >= 2 else { return [] }
        let cosT = cos(tolGradi * .pi / 180)
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        var inizio = pts[0]
        var dirRif: SIMD3<Float>? = nil
        for i in 1..<pts.count {
            let d = pts[i] - pts[i - 1]
            if simd_length(d) < 1e-6 { continue }
            let dir = simd_normalize(d)
            if let r = dirRif, simd_dot(r, dir) < cosT {
                segs.append((inizio, pts[i - 1])); inizio = pts[i - 1]; dirRif = dir
            } else if dirRif == nil { dirRif = dir }
        }
        segs.append((inizio, pts.last!))
        return segs
    }

    private func geometriaSegmenti(_ segs: [(SIMD3<Float>, SIMD3<Float>)], colore: UIColor) -> SCNGeometry? {
        guard !segs.isEmpty else { return nil }
        var verts: [SCNVector3] = []; var idx: [Int32] = []
        for (a, b) in segs {
            let i = Int32(verts.count)
            verts.append(SCNVector3(a.x, a.y, a.z)); verts.append(SCNVector3(b.x, b.y, b.z))
            idx += [i, i + 1]
        }
        let src = SCNGeometrySource(vertices: verts)
        let el = SCNGeometryElement(indices: idx, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [el])
        let m = SCNMaterial(); m.diffuse.contents = colore; m.lightingModel = .constant
        m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
        g.materials = [m]
        return g
    }

    private func ridisegnaPerimetro(_ segs: [(SIMD3<Float>, SIMD3<Float>)]) {
        perimetroNode.childNodes.forEach { $0.removeFromParentNode() }
        // Piano di sezione TRASLUCIDO sul 3D (fase 1: posizionamento): un quad
        // orizzontale alla quota corrente, esteso sul footprint della mesh.
        let su = simd_normalize(gravitaSu)
        let (lo, hi) = mesh.aabb
        var uMin = Float.greatestFiniteMagnitude, uMax = -uMin, vMin = uMin, vMax = -uMin
        for cx in [lo.x, hi.x] { for cy in [lo.y, hi.y] { for cz in [lo.z, hi.z] {
            let p = SIMD3<Float>(cx, cy, cz)
            let u = simd_dot(p, perimE1), w = simd_dot(p, perimE2)
            uMin = min(uMin, u); uMax = max(uMax, u); vMin = min(vMin, w); vMax = max(vMax, w)
        }}}
        if uMax > uMin {
            let base = su * sliceS0
            let q = [base + perimE1 * uMin + perimE2 * vMin, base + perimE1 * uMax + perimE2 * vMin,
                     base + perimE1 * uMax + perimE2 * vMax, base + perimE1 * uMin + perimE2 * vMax]
                .map { SCNVector3($0.x, $0.y, $0.z) }
            let src = SCNGeometrySource(vertices: q)
            let el = SCNGeometryElement(indices: [Int32](arrayLiteral: 0, 1, 2, 0, 2, 3), primitiveType: .triangles)
            let g = SCNGeometry(sources: [src], elements: [el])
            let m = SCNMaterial(); m.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.18)
            m.isDoubleSided = true; m.lightingModel = .constant; m.writesToDepthBuffer = false
            g.materials = [m]
            perimetroNode.addChildNode(SCNNode(geometry: g))
        }
        // contorno della sezione (ciano acceso) = guida da ricalcare: linee + pallini
        if let g = geometriaSegmenti(segs, colore: UIColor.systemTeal) {
            perimetroNode.addChildNode(SCNNode(geometry: g))
        }
        if !segs.isEmpty {
            let rp = CGFloat(estensioneMesh) * 0.006
            let passo = max(1, segs.count / 160)   // ~160 pallini max
            var k = 0
            while k < segs.count {
                let m = (segs[k].0 + segs[k].1) * 0.5
                let s = SCNSphere(radius: rp); s.segmentCount = 8
                let mat = SCNMaterial(); mat.diffuse.contents = UIColor.systemTeal
                mat.lightingModel = .constant; mat.readsFromDepthBuffer = false; mat.writesToDepthBuffer = false
                s.materials = [mat]
                let node = SCNNode(geometry: s); node.position = SCNVector3(m.x, m.y, m.z)
                perimetroNode.addChildNode(node)
                k += passo
            }
        }
        // traccia dell'utente a linee RETTE (giallo) + punti di controllo
        var traccia = puntiPerimetro
        if chiudiPerimetro, puntiPerimetro.count >= 3, let f = puntiPerimetro.first { traccia.append(f) }
        if traccia.count >= 2 {
            var ts: [(SIMD3<Float>, SIMD3<Float>)] = []
            for i in 0..<(traccia.count - 1) { ts.append((traccia[i], traccia[i + 1])) }
            if let g = geometriaSegmenti(ts, colore: .systemYellow) {
                perimetroNode.addChildNode(SCNNode(geometry: g))
            }
        }
        let r = CGFloat(estensioneMesh) * 0.014
        for p in puntiPerimetro {
            let s = SCNSphere(radius: r); s.segmentCount = 12
            let m = SCNMaterial(); m.diffuse.contents = UIColor.systemYellow
            m.lightingModel = .constant; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
            s.materials = [m]
            let node = SCNNode(geometry: s)
            node.position = SCNVector3(p.x, p.y, p.z)
            perimetroNode.addChildNode(node)
        }
    }

    /// Genera i piani da ciò che hai marcato: ogni SEME (tocco) è un piano a sé;
    /// una SELEZIONE (pennello/rettangolo/lazo) fa UN solo piano (cresce da tutto
    /// il segno, non lo spezza). Più piani = più semi, o più selezioni separate.
    func generaDaMarcatura() {
        if numSemi > 0 { cresciTuttiSemi() }
        else if !selezione.isEmpty { trovaPianoDaTratto() }
    }

    /// Azzera la marcatura corrente (semi + selezione) senza generare.
    func annullaMarcatura() { annullaSemi(); deselezionaTutto() }

    /// Rende attivo un piano e ridisegna. In multi-selezione il tocco AGGIUNGE/
    /// TOGLIE dal set; altrimenti seleziona solo quello.
    func selezionaFacciaAttiva(_ id: Int) {
        if multiSelezione {
            if facceSelezionate.contains(id) { facceSelezionate.remove(id) } else { facceSelezionate.insert(id) }
        } else {
            facceSelezionate = [id]
        }
        facciaAttivaId = id
        calcolaAssiNavigazione()
        mostraPiani = true   // le maniglie vivono sul layer dei piani: assicurane la visibilità
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Mostra/nascondi UN piano (solo visualizzazione, non lo elimina). Per
    /// valutare i piani rilevati uno alla volta.
    func toggleVisibilitaFaccia(_ id: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }) else { return }
        facce[i].nascosto.toggle()
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Mostra tutti i piani nascosti.
    func mostraTuttiIPiani() {
        for i in facce.indices { facce[i].nascosto = false }
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Piani su cui agire: i selezionati, o l'attivo se il set è vuoto.
    private var bersagli: [Int] {
        facceSelezionate.isEmpty ? (facciaAttivaId.map { [$0] } ?? []) : Array(facceSelezionate)
    }

    var puoAllinearePianiInAltezza: Bool {
        let su = simd_normalize(gravitaSu)
        return facce.filter {
            guard let normal = $0.pianoNormale,
                  let polygon = $0.poligono, polygon.count >= 3 else { return false }
            return abs(simd_dot(simd_normalize(normal), su)) < 0.65
        }.count >= 2
    }

    /// Porta base e sommita' dei piani verticali alle quote del piano strutturale
    /// piu' esteso. Ogni vertice si muove lungo la verticale contenuta nel proprio
    /// piano, quindi posizione, inclinazione e larghezza restano inalterate.
    func allineaPianiInAltezza() {
        let su = simd_normalize(gravitaSu)
        let candidati: [(index: Int, min: Float, max: Float, area: Float)] = facce.indices.compactMap { index in
            guard let normal = facce[index].pianoNormale,
                  abs(simd_dot(simd_normalize(normal), su)) < 0.65,
                  let polygon = facce[index].poligono, polygon.count >= 3 else { return nil }
            let quote = polygon.map { simd_dot($0, su) }
            guard let minQuota = quote.min(), let maxQuota = quote.max(),
                  maxQuota - minQuota > 1e-5 else { return nil }
            return (index, minQuota, maxQuota, areaPoligono(facce[index]) ?? 0)
        }
        guard candidati.count >= 2,
              let riferimento = candidati.max(by: { $0.area < $1.area }) else { return }

        registraUndo()
        for candidato in candidati {
            guard let normal0 = facce[candidato.index].pianoNormale,
                  var polygon = facce[candidato.index].poligono else { continue }
            let normal = simd_normalize(normal0)
            var asseVerticale = su - normal * simd_dot(su, normal)
            guard simd_length(asseVerticale) > 1e-5 else { continue }
            asseVerticale = simd_normalize(asseVerticale)
            let quotaPerUnita = simd_dot(asseVerticale, su)
            guard abs(quotaPerUnita) > 1e-5 else { continue }
            let altezzaCorrente = candidato.max - candidato.min
            let altezzaRiferimento = riferimento.max - riferimento.min

            for vertexIndex in polygon.indices {
                let quota = simd_dot(polygon[vertexIndex], su)
                let posizione = (quota - candidato.min) / altezzaCorrente
                let quotaTarget = riferimento.min + posizione * altezzaRiferimento
                polygon[vertexIndex] += asseVerticale * ((quotaTarget - quota) / quotaPerUnita)
            }
            facce[candidato.index].poligono = polygon
            facce[candidato.index].pianoPunto = polygon.reduce(
                SIMD3<Float>(repeating: 0), +) / Float(polygon.count)
        }
        saldaPianiAdiacenti()
        mostraPiani = true
        ridisegnaFacce()
        ridisegnaPiani()
    }

    /// Regola l'altezza di TUTTI i piani selezionati (cima/base).
    func regolaAltezzaSelezionate(cima: Bool, verso: Float) {
        for id in bersagli { regolaAltezzaFaccia(id, cima: cima, verso: verso) }
    }
    /// Fitta alla mesh TUTTI i piani selezionati.
    func fittaSelezionateAllaMesh() { for id in bersagli { fittaPianoAllaMesh(id) } }

    /// Usa il tratto selezionato come indicazione semantica: "questa e' la faccia".
    /// Il tratto non diventa il piano finale; serve solo per stimare il piano
    /// dominante, ripulire eventuali outlier e far crescere la superficie connessa.
    func trovaPianoDaTratto() {
        guard !selezione.isEmpty else { return }
        registraUndo()
        let adj = adiacenza()
        guard let id = creaPianoGuidatoDaTratto(selezione, adiacenza: adj) else { return }
        facce.removeAll { $0.triangoli.isEmpty }
        stimaGravita()
        classificaPerGravita()
        generaPoligono(perFaccia: id)
        facciaAttivaId = id
        pianiGenerati = facce.count
        mostraProxy = true; mostraPiani = true
        deselezionaTutto()
        strumento = .facce
        ridisegnaFacce(); ridisegnaPiani()
    }

    @discardableResult
    private func creaPianoGuidatoDaTratto(_ tratto: Set<Int>, adiacenza adj: EditableMesh.Adiacenza) -> Int? {
        let su = simd_normalize(gravitaSu)
        let (lo, hi) = mesh.aabb
        let ext = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
        let tolDist = max(ext * 0.012, 1e-4)
        let cosNormale = cos(28 * Float.pi / 180)
        let areaTotale = mesh.areaTriangoli(Set(mesh.triangles.indices))
        let areaTratto = max(mesh.areaTriangoli(tratto), areaTotale * 0.0002)
        let minAreaComponente = max(areaTotale * 0.00025, areaTratto * 0.10)

        func areaTri(_ ti: Int) -> Float {
            let t = mesh.triangles[ti]
            return simd_length(simd_cross(mesh.vertices[Int(t.y)] - mesh.vertices[Int(t.x)],
                                          mesh.vertices[Int(t.z)] - mesh.vertices[Int(t.x)])) * 0.5
        }

        func normaleCanonica(_ n0: SIMD3<Float>) -> SIMD3<Float> {
            var n = simd_normalize(n0)
            let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
            if ax >= ay && ax >= az {
                if n.x < 0 { n = -n }
            } else if ay >= ax && ay >= az {
                if n.y < 0 { n = -n }
            } else if n.z < 0 {
                n = -n
            }
            return n
        }

        struct ClusterNormale {
            var triangoli: Set<Int>
            var normaleAcc: SIMD3<Float>
            var area: Float

            var normale: SIMD3<Float> {
                simd_length(normaleAcc) > 1e-6 ? simd_normalize(normaleAcc) : SIMD3<Float>(0, 0, 1)
            }
        }

        let cosCluster = cos(18 * Float.pi / 180)
        var clusters: [ClusterNormale] = []
        for ti in tratto {
            let area = areaTri(ti)
            guard area > 1e-9 else { continue }
            let nt = normaleCanonica(mesh.normale(ti))
            if let ci = clusters.indices.max(by: { abs(simd_dot(nt, clusters[$0].normale)) < abs(simd_dot(nt, clusters[$1].normale)) }),
               abs(simd_dot(nt, clusters[ci].normale)) > cosCluster {
                let nn = simd_dot(nt, clusters[ci].normale) < 0 ? -nt : nt
                clusters[ci].triangoli.insert(ti)
                clusters[ci].normaleAcc += nn * area
                clusters[ci].area += area
            } else {
                clusters.append(ClusterNormale(triangoli: [ti], normaleAcc: nt * area, area: area))
            }
        }
        guard !clusters.isEmpty else { return nil }

        let ordinati = clusters.sorted { $0.area > $1.area }
        let migliore = ordinati[0]
        let clusterPiano = ordinati
            .filter { abs(simd_dot($0.normale, su)) < 0.65 && $0.area >= migliore.area * 0.35 }
            .max(by: { $0.area < $1.area }) ?? migliore
        let n = clusterPiano.normale
        var media = SIMD3<Float>(0, 0, 0)
        var offsetAcc: Float = 0
        var pesoAcc: Float = 0
        for ti in clusterPiano.triangoli {
            let area = max(areaTri(ti), 1e-9)
            let c = mesh.centroid(mesh.triangles[ti])
            media += c * area
            offsetAcc += simd_dot(c, n) * area
            pesoAcc += area
        }
        guard pesoAcc > 1e-8 else { return nil }
        media /= pesoAcc
        let offset = offsetAcc / pesoAcc
        let p0 = media + n * (offset - simd_dot(media, n))

        var asseX = simd_cross(su, n)
        if simd_length(asseX) < 1e-5 { asseX = simd_cross(SIMD3<Float>(1, 0, 0), n) }
        asseX = simd_normalize(asseX)
        let asseY = simd_normalize(simd_cross(n, asseX))
        var seedMinX = Float.greatestFiniteMagnitude, seedMaxX = -seedMinX
        var seedMinY = seedMinX, seedMaxY = -seedMinX
        for ti in tratto {
            let c = mesh.centroid(mesh.triangles[ti])
            let x = simd_dot(c - p0, asseX)
            let y = simd_dot(c - p0, asseY)
            seedMinX = min(seedMinX, x); seedMaxX = max(seedMaxX, x)
            seedMinY = min(seedMinY, y); seedMaxY = max(seedMaxY, y)
        }
        let seedW = max(seedMaxX - seedMinX, ext * 0.04)
        let seedH = max(seedMaxY - seedMinY, ext * 0.04)
        let margineX = max(seedW * 1.4, ext * 0.08)
        let margineY = max(seedH * 1.4, ext * 0.08)

        // Metodo guidato globale: il tratto definisce il piano, poi si raccolgono
        // tutte le parti della mesh compatibili con quel piano. Non richiede
        // continuita' topologica, quindi recupera facciate interrotte da buchi.
        var candidati = Set<Int>()
        for ti in mesh.triangles.indices {
            let c = mesh.centroid(mesh.triangles[ti])
            let dist = abs(simd_dot(c - p0, n))
            let allineato = abs(simd_dot(mesh.normale(ti), n)) > cosNormale
            if dist < tolDist && allineato {
                candidati.insert(ti)
            }
        }

        let comps = mesh.componentiConnesse(candidati)
        var cresciuto = Set<Int>()
        for c in comps {
            let toccaTratto = !c.isDisjoint(with: tratto)
            let area = mesh.areaTriangoli(c)
            var compMinX = Float.greatestFiniteMagnitude, compMaxX = -compMinX
            var compMinY = compMinX, compMaxY = -compMinX
            for ti in c {
                let cc = mesh.centroid(mesh.triangles[ti])
                let x = simd_dot(cc - p0, asseX)
                let y = simd_dot(cc - p0, asseY)
                compMinX = min(compMinX, x); compMaxX = max(compMaxX, x)
                compMinY = min(compMinY, y); compMaxY = max(compMaxY, y)
            }
            let overlapX = compMaxX >= seedMinX - margineX && compMinX <= seedMaxX + margineX
            let overlapY = compMaxY >= seedMinY - margineY && compMinY <= seedMaxY + margineY
            if toccaTratto || (area >= minAreaComponente && overlapX && overlapY) {
                cresciuto.formUnion(c)
            }
        }
        if cresciuto.isEmpty { cresciuto = candidati }
        guard cresciuto.count >= 6 else { return nil }
        var centroFinale = SIMD3<Float>(0, 0, 0)
        var offsetFinale: Float = 0
        var pesoFinale: Float = 0
        for ti in cresciuto {
            let area = max(areaTri(ti), 1e-9)
            let c = mesh.centroid(mesh.triangles[ti])
            centroFinale += c * area
            offsetFinale += simd_dot(c, n) * area
            pesoFinale += area
        }
        let p2: SIMD3<Float>
        if pesoFinale > 1e-8 {
            centroFinale /= pesoFinale
            let off = offsetFinale / pesoFinale
            p2 = centroFinale + n * (off - simd_dot(centroFinale, n))
        } else {
            p2 = p0
        }

        for j in facce.indices { facce[j].triangoli.subtract(cresciuto) }
        let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
        var f = FacciaProxy(id: prossimoIdFaccia, nome: "Piano \(prossimoIdFaccia)", colore: colore)
        prossimoIdFaccia += 1
        f.triangoli = cresciuto
        f.pianoPunto = p2
        f.pianoNormale = n
        f.erroreRms = mesh.rmsDalPiano(cresciuto, punto: p2, normale: f.pianoNormale!)
        facce.append(f)
        return f.id
    }

    /// Usa la selezione come seme. `split=false` → un solo piano da tutta la
    /// selezione (più zone unite in un piano). `split=true` → un piano per ogni
    /// zona connessa della selezione (più zone → più piani).
    func cresciDaSelezione(split: Bool = false) {
        guard !selezione.isEmpty else { return }
        registraUndo()
        let semi = split ? mesh.componentiConnesse(selezione) : [selezione]
        let adj = adiacenza()
        var ultimo: Int? = nil
        for seme in semi { if let id = creaPianoDa(seme: seme, adiacenza: adj) { ultimo = id } }
        facce.removeAll { $0.triangoli.isEmpty }
        stimaGravita()
        classificaPerGravita()
        for f in facce { generaPoligono(perFaccia: f.id) }
        if let id = ultimo { facciaAttivaId = id }
        pianiGenerati = facce.count
        mostraProxy = true; mostraPiani = true
        deselezionaTutto()
        strumento = .facce
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// #12 + #13 — Snap "Manhattan": costruisce una terna ortogonale dall'edificio
    /// (su = gravità, asse1 = normale della facciata maggiore, asse2 = su×asse1) e
    /// aggancia ogni piano all'asse più vicino. CONSERVATIVO: snappa solo se già
    /// entro 12° (non forza muri genuinamente obliqui). Effetto: i ritorni diventano
    /// esattamente ⟂ alla facciata (#12) e tutti i muri ⟂/∥ tra loro (#13).
    private func snapManhattan() {
        let su = gravitaSu
        var axis1: SIMD3<Float>? = nil; var areaMax: Float = 0
        for f in facce {
            guard let n = f.pianoNormale else { continue }
            let horiz = n - simd_dot(n, su) * su           // componente orizzontale
            if simd_length(horiz) < 0.3 { continue }       // orizzontale → salta
            let a = mesh.areaTriangoli(f.triangoli)
            if a > areaMax { areaMax = a; axis1 = simd_normalize(horiz) }
        }
        guard let a1 = axis1 else { return }
        let a2 = simd_normalize(simd_cross(su, a1))
        let cand = [a1, -a1, a2, -a2, su, -su]
        let cos12 = cos(12 * Float.pi / 180)
        for i in facce.indices {
            guard let n = facce[i].pianoNormale else { continue }
            if let best = cand.max(by: { simd_dot(n, $0) < simd_dot(n, $1) }),
               simd_dot(n, best) > cos12 {
                aggiornaNormaleFaccia(facce[i].id, best)
            }
        }
    }

    /// Crea una nuova faccia (colore successivo della palette) e la rende attiva.
    func nuovaFaccia() {
        let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
        let f = FacciaProxy(id: prossimoIdFaccia, nome: "Layer \(prossimoIdFaccia)", colore: colore)
        prossimoIdFaccia += 1
        facce.append(f)
        facciaAttivaId = f.id
        facceSelezionate = [f.id]
        mostraProxy = true
        ridisegnaFacce()
    }

    // MARK: Crescita dal pennello + revisione piani (§3, brush-seeded)

    /// Modalita' multipunto: i tocchi sulla mesh diventano riferimenti per i
    /// piani corrispondenti; il rifit viene eseguito solo alla conferma.
    @Published var attendePuntoZero = false
    @Published private(set) var numPuntiRevisione = 0
    private var puntiRevisionePiani: [PuntoRevisionePiano] = []

    /// Espande la faccia attiva dal pennellato al MURO (region growing per
    /// normale+profondità): un segno piccolo cattura tutta la facciata.
    func espandiAlPiano() {
        guard let id = facciaAttivaId,
              let i = facce.firstIndex(where: { $0.id == id }),
              !facce[i].triangoli.isEmpty,
              let (p, n) = mesh.fitPianoRANSAC(facce[i].triangoli) else { return }
        registraUndo()
        let cresciuto = mesh.crescePianare(da: facce[i].triangoli, normale: n, punto: p,
                                           tolGradi: Float(tolleranzaNormaleGradi), adiacenza: adiacenza())
        for j in facce.indices where j != i { facce[j].triangoli.subtract(cresciuto) }
        facce[i].triangoli = cresciuto
        if let (p2, n2) = mesh.fitPianoRANSAC(cresciuto) {
            facce[i].pianoPunto = p2; facce[i].pianoNormale = n2
            facce[i].erroreRms = mesh.rmsDalPiano(cresciuto, punto: p2, normale: n2)
        }
        mostraPiani = true
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Tocco→piano: l'utente tocca una superficie e nasce LÌ un nuovo piano,
    /// cresciuto per region-growing dal triangolo colpito. Deterministico
    /// (niente RANSAC casuale) e scelto dall'utente: marca i piani che vuoi.
    func toccaPerPiano(triangolo i: Int) {
        guard i >= 0, i < mesh.triangles.count else { return }
        // Tocchi un piano GIÀ riconosciuto → lo SELEZIONI (non ne crei un altro).
        if let g = facce.first(where: { $0.triangoli.contains(i) }) {
            facciaAttivaId = g.id
            ridisegnaFacce(); ridisegnaPiani()
            return
        }
        registraUndo()
        let p = mesh.centroid(mesh.triangles[i])
        let n = mesh.normale(i)
        let cresciuto = mesh.crescePianare(da: [i], normale: n, punto: p,
                                           tolGradi: Float(tolleranzaNormaleGradi), adiacenza: adiacenza())
        // non rubare triangoli a piani già marcati
        for j in facce.indices { facce[j].triangoli.subtract(cresciuto) }
        let colore = FacciaProxy.palette[facce.count % FacciaProxy.palette.count]
        var f = FacciaProxy(id: prossimoIdFaccia,
                            nome: "Piano \(prossimoIdFaccia)", colore: colore)
        prossimoIdFaccia += 1
        f.triangoli = cresciuto
        if let (p2, n2) = mesh.fitPianoRANSAC(cresciuto) {
            f.pianoPunto = p2; f.pianoNormale = n2
            f.erroreRms = mesh.rmsDalPiano(cresciuto, punto: p2, normale: n2)
            f.tipo = abs(n2.y) > 0.7 ? .orizzontale : .facciata
        } else {
            f.pianoPunto = p; f.pianoNormale = n
        }
        facce.append(f)
        facciaAttivaId = f.id
        facce.removeAll { $0.triangoli.isEmpty }
        generaPoligono(perFaccia: f.id)
        pianiGenerati = facce.count
        mostraProxy = true; mostraPiani = true
        ridisegnaFacce(); ridisegnaPiani()
    }

    /// Avvia una nuova revisione o annulla quella in corso.
    func attivaPuntoZero() {
        if attendePuntoZero {
            annullaRevisionePiani()
        } else {
            errore = nil
            mostraSviluppoPiani = false
            mostraMesh = true
            mostraPiani = true
            puntiRevisionePiani.removeAll()
            numPuntiRevisione = 0
            ridisegnaPuntiRevisione()
            attendePuntoZero = true
        }
    }

    func annullaRevisionePiani() {
        attendePuntoZero = false
        puntiRevisionePiani.removeAll()
        numPuntiRevisione = 0
        ridisegnaPuntiRevisione()
    }

    /// Associa il punto al piano che possiede il triangolo toccato. Se il punto
    /// cade su una sporgenza non assegnata, usa distanza, normale e poligono per
    /// risalire alla facciata architettonica sottostante.
    func aggiungiPuntoRevisione(_ world: SCNVector3, triangolo: Int) {
        guard attendePuntoZero, triangolo >= 0, triangolo < mesh.triangles.count else { return }
        let p = SIMD3<Float>(world.x, world.y, world.z)
        guard let id = pianoAssociatoAlPunto(p, triangolo: triangolo) else {
            errore = "Il punto non e' associabile a un piano. Tocca piu' vicino alla facciata."
            return
        }
        puntiRevisionePiani.append(PuntoRevisionePiano(punto: p, triangolo: triangolo, pianoId: id))
        numPuntiRevisione = puntiRevisionePiani.count
        facciaAttivaId = id
        facceSelezionate.insert(id)
        mostraPiani = true
        ridisegnaPuntiRevisione()
        ridisegnaPiani()
    }

    private func pianoAssociatoAlPunto(_ punto: SIMD3<Float>, triangolo: Int) -> Int? {
        if let face = facce.first(where: { $0.triangoli.contains(triangolo) }) { return face.id }
        let normalHit = mesh.normale(triangolo)
        var best: (id: Int, score: Float)?
        for face in facce {
            guard let point = face.pianoPunto, let normal0 = face.pianoNormale else { continue }
            let normal = simd_normalize(normal0)
            let projected = punto - normal * simd_dot(punto - point, normal)
            let planeDistance = abs(simd_dot(punto - point, normal))
            let normalPenalty = (1 - abs(simd_dot(normalHit, normal))) * estensioneMesh * 0.06
            var outlinePenalty: Float = 0
            if let polygon = face.poligono, polygon.count >= 3,
               !puntoNelPoligonoPiano(projected, polygon: polygon, point: point, normal: normal) {
                outlinePenalty = (polygon.indices.map {
                    distanzaPuntoSegmento(projected, polygon[$0], polygon[($0 + 1) % polygon.count])
                }.min() ?? estensioneMesh) * 0.35
            }
            let score = planeDistance + normalPenalty + outlinePenalty
            if best == nil || score < best!.score { best = (face.id, score) }
        }
        guard let result = best, result.score <= estensioneMesh * 0.18 else { return nil }
        return result.id
    }

    /// Applica in un unico passaggio annullabile il rifit dei piani indicati e
    /// rende esatti gli spigoli condivisi fra le facciate adiacenti.
    func applicaRevisionePiani() {
        guard !puntiRevisionePiani.isEmpty else { return }
        registraUndo()
        let gruppi = Dictionary(grouping: puntiRevisionePiani, by: \.pianoId)
        var aggiornati = Set<Int>()
        for (id, punti) in gruppi where rifittaPianoRevisionato(id, riferimenti: punti) {
            aggiornati.insert(id)
        }
        if !aggiornati.isEmpty { saldaPianiAdiacenti() }
        attendePuntoZero = false
        puntiRevisionePiani.removeAll()
        numPuntiRevisione = 0
        ridisegnaPuntiRevisione()
        mostraPiani = true
        ridisegnaFacce()
        ridisegnaPiani()
    }

    private func rifittaPianoRevisionato(
        _ id: Int,
        riferimenti: [PuntoRevisionePiano]
    ) -> Bool {
        guard let index = facce.firstIndex(where: { $0.id == id }), !riferimenti.isEmpty else { return false }
        if facce[index].poligono == nil { generaPoligono(perFaccia: id) }
        guard let oldPoint = facce[index].pianoPunto,
              let oldNormal0 = facce[index].pianoNormale,
              let polygon = facce[index].poligono,
              polygon.count >= 3 else { return false }
        let oldNormal = simd_normalize(oldNormal0)
        let su = simd_normalize(gravitaSu)
        let anchorMean = riferimenti.map(\.punto).reduce(SIMD3<Float>(repeating: 0), +)
            / Float(riferimenti.count)
        let anchorQuota = mediana(riferimenti.map { simd_dot($0.punto, su) })

        var oldRight = simd_cross(su, oldNormal)
        if simd_length(oldRight) < 1e-5 { oldRight = simd_cross(SIMD3<Float>(1, 0, 0), oldNormal) }
        oldRight = simd_normalize(oldRight)
        let oldUp = simd_normalize(simd_cross(oldNormal, oldRight))
        let oldXs = polygon.map { simd_dot($0 - oldPoint, oldRight) }
        let oldMinX = (oldXs.min() ?? -estensioneMesh) - estensioneMesh * 0.06
        let oldMaxX = (oldXs.max() ?? estensioneMesh) + estensioneMesh * 0.06
        let cosOrientation = cos(55 * Float.pi / 180)

        // La fascia bassa indicata dai riferimenti stima l'inclinazione del muro
        // senza far prevalere balconi e parapetti presenti alle quote superiori.
        var orientationSupport = mesh.crescePianare(
            da: Set(riferimenti.map(\.triangolo)),
            normale: oldNormal,
            punto: anchorMean,
            tolGradi: 35,
            tolDistFraz: 0.018,
            adiacenza: adiacenza())
        for triangleIndex in mesh.triangles.indices {
            let center = mesh.centroid(mesh.triangles[triangleIndex])
            let quota = simd_dot(center, su)
            guard quota >= anchorQuota - estensioneMesh * 0.04,
                  quota <= anchorQuota + estensioneMesh * 0.22,
                  abs(simd_dot(center - anchorMean, oldNormal)) <= estensioneMesh * 0.06,
                  abs(simd_dot(mesh.normale(triangleIndex), oldNormal)) >= cosOrientation else { continue }
            let x = simd_dot(center - oldPoint, oldRight)
            if x >= oldMinX, x <= oldMaxX { orientationSupport.insert(triangleIndex) }
        }
        guard orientationSupport.count >= 3,
              let (_, fittedNormal0) = mesh.fitPianoRANSAC(
                orientationSupport, iters: 220, tolDistFraz: 0.0045, tolGradi: 30) else { return false }
        var fittedNormal = simd_normalize(fittedNormal0)
        if simd_dot(fittedNormal, oldNormal) < 0 { fittedNormal = -fittedNormal }

        // Tutti i riferimenti hanno peso uguale sull'offset: la mediana evita che
        // un singolo tocco accidentale sposti l'intera facciata.
        let anchorOffset = mediana(riferimenti.map { simd_dot($0.punto, fittedNormal) })
        // Il punto rappresentativo precedente viene proiettato sul nuovo piano:
        // in questo modo i riferimenti non introducono traslazioni nel piano.
        let fittedPoint = oldPoint + fittedNormal
            * (anchorOffset - simd_dot(oldPoint, fittedNormal))

        var right = simd_cross(su, fittedNormal)
        if simd_length(right) < 1e-5 { right = simd_cross(SIMD3<Float>(1, 0, 0), fittedNormal) }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(fittedNormal, right))
        let projectedOldX = polygon.map { simd_dot($0 - fittedPoint, right) }
        let minAllowedX = (projectedOldX.min() ?? -estensioneMesh) - estensioneMesh * 0.08
        let maxAllowedX = (projectedOldX.max() ?? estensioneMesh) + estensioneMesh * 0.08
        let cosSupport = cos(50 * Float.pi / 180)
        let distanceTolerance = max(estensioneMesh * 0.022, 1e-4)
        var support = Set<Int>()
        for triangleIndex in mesh.triangles.indices {
            let center = mesh.centroid(mesh.triangles[triangleIndex])
            guard abs(simd_dot(center - fittedPoint, fittedNormal)) <= distanceTolerance,
                  abs(simd_dot(mesh.normale(triangleIndex), fittedNormal)) >= cosSupport else { continue }
            let x = simd_dot(center - fittedPoint, right)
            if x >= minAllowedX, x <= maxAllowedX { support.insert(triangleIndex) }
        }
        if support.count < 8 { support = orientationSupport }
        guard !support.isEmpty else { return false }

        // Conserva forma, dimensioni e numero di vertici del poligono. Cambiano
        // soltanto il piano su cui vive e il suo orientamento nello spazio.
        let transformedPolygon = polygon.map { vertex -> SIMD3<Float> in
            let local = vertex - oldPoint
            let x = simd_dot(local, oldRight)
            let y = simd_dot(local, oldUp)
            return fittedPoint + right * x + up * y
        }

        facce[index].pianoPunto = fittedPoint
        facce[index].pianoNormale = fittedNormal
        facce[index].triangoli = support
        facce[index].erroreRms = mesh.rmsDalPiano(support, punto: fittedPoint, normale: fittedNormal)
        facce[index].poligono = transformedPolygon
        return true
    }

    /// Estende le coppie di facciate fino alla loro retta d'intersezione e
    /// assegna a entrambe gli stessi estremi, creando un edge realmente condiviso.
    private func saldaPianiAdiacenti() {
        guard facce.count >= 2 else { return }
        let su = simd_normalize(gravitaSu)
        let maxDistance = estensioneMesh * 0.12
        let minOverlap = estensioneMesh * 0.015

        func edgeVicino(
            _ polygon: [SIMD3<Float>],
            linePoint: SIMD3<Float>,
            lineDirection: SIMD3<Float>
        ) -> (index: Int, distance: Float, minT: Float, maxT: Float)? {
            var result: (Int, Float, Float, Float)?
            for k in polygon.indices {
                let a = polygon[k], b = polygon[(k + 1) % polygon.count]
                let edge = b - a
                guard simd_length(edge) > 1e-6,
                      abs(simd_dot(simd_normalize(edge), lineDirection)) >= 0.65 else { continue }
                let middle = (a + b) * 0.5
                let projected = linePoint + lineDirection * simd_dot(middle - linePoint, lineDirection)
                let distance = simd_length(middle - projected)
                let ta = simd_dot(a - linePoint, lineDirection)
                let tb = simd_dot(b - linePoint, lineDirection)
                if result == nil || distance < result!.1 {
                    result = (k, distance, min(ta, tb), max(ta, tb))
                }
            }
            return result
        }

        for _ in 0..<2 {
            for aIndex in facce.indices {
                for bIndex in facce.indices where bIndex > aIndex {
                    guard let normalA0 = facce[aIndex].pianoNormale,
                          let normalB0 = facce[bIndex].pianoNormale,
                          let pointA = facce[aIndex].pianoPunto,
                          let pointB = facce[bIndex].pianoPunto,
                          var polygonA = facce[aIndex].poligono, polygonA.count >= 3,
                          var polygonB = facce[bIndex].poligono, polygonB.count >= 3 else { continue }
                    let normalA = simd_normalize(normalA0)
                    let normalB = simd_normalize(normalB0)
                    guard abs(simd_dot(normalA, su)) < 0.65,
                          abs(simd_dot(normalB, su)) < 0.65,
                          abs(simd_dot(normalA, normalB)) < cos(15 * Float.pi / 180) else { continue }
                    let cross = simd_cross(normalA, normalB)
                    guard simd_length(cross) > 1e-4 else { continue }
                    let direction = simd_normalize(cross)
                    guard abs(simd_dot(direction, su)) >= 0.55,
                          let linePoint = puntoSuRetta(
                            nA: normalA, pA: pointA, nB: normalB, pB: pointB, dir: direction),
                          let edgeA = edgeVicino(polygonA, linePoint: linePoint, lineDirection: direction),
                          let edgeB = edgeVicino(polygonB, linePoint: linePoint, lineDirection: direction),
                          edgeA.distance <= maxDistance, edgeB.distance <= maxDistance else { continue }
                    let overlapLow = max(edgeA.minT, edgeB.minT)
                    let overlapHigh = min(edgeA.maxT, edgeB.maxT)
                    guard overlapHigh - overlapLow >= minOverlap else { continue }
                    let low = min(edgeA.minT, edgeB.minT)
                    let high = max(edgeA.maxT, edgeB.maxT)
                    let sharedLow = linePoint + direction * low
                    let sharedHigh = linePoint + direction * high

                    func assign(_ polygon: inout [SIMD3<Float>], edge: Int) {
                        let next = (edge + 1) % polygon.count
                        let edgeT = simd_dot(polygon[edge] - linePoint, direction)
                        let nextT = simd_dot(polygon[next] - linePoint, direction)
                        if edgeT <= nextT {
                            polygon[edge] = sharedLow; polygon[next] = sharedHigh
                        } else {
                            polygon[edge] = sharedHigh; polygon[next] = sharedLow
                        }
                    }
                    assign(&polygonA, edge: edgeA.index)
                    assign(&polygonB, edge: edgeB.index)
                    facce[aIndex].poligono = polygonA
                    facce[bIndex].poligono = polygonB
                }
            }
        }
    }

    private func mediana(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) * 0.5 : sorted[middle]
    }

    private func distanzaPuntoSegmento(
        _ point: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>
    ) -> Float {
        let edge = b - a
        let denominator = simd_length_squared(edge)
        guard denominator > 1e-10 else { return simd_length(point - a) }
        let t = max(0, min(1, simd_dot(point - a, edge) / denominator))
        return simd_length(point - (a + edge * t))
    }

    private func puntoNelPoligonoPiano(
        _ point3D: SIMD3<Float>,
        polygon: [SIMD3<Float>],
        point origin: SIMD3<Float>,
        normal: SIMD3<Float>
    ) -> Bool {
        var right = simd_cross(gravitaSu, normal)
        if simd_length(right) < 1e-5 { right = simd_cross(SIMD3<Float>(1, 0, 0), normal) }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(normal, right))
        let query = SIMD2<Float>(simd_dot(point3D - origin, right), simd_dot(point3D - origin, up))
        let polygon2D = polygon.map {
            SIMD2<Float>(simd_dot($0 - origin, right), simd_dot($0 - origin, up))
        }
        var inside = false
        var previous = polygon2D.count - 1
        for current in polygon2D.indices {
            let a = polygon2D[current], b = polygon2D[previous]
            if (a.y > query.y) != (b.y > query.y) {
                let crossingX = (b.x - a.x) * (query.y - a.y) / (b.y - a.y) + a.x
                if query.x < crossingX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private func ridisegnaPuntiRevisione() {
        revisionePianiNode.childNodes.forEach { $0.removeFromParentNode() }
        for reference in puntiRevisionePiani {
            let color = facce.first(where: { $0.id == reference.pianoId })?.colore ?? UIColor.systemYellow
            let sphere = SCNSphere(radius: max(raggioMarker * 0.75, 0.001))
            sphere.segmentCount = 16
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.emission.contents = color.withAlphaComponent(0.35)
            material.lightingModel = .constant
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(reference.punto.x, reference.punto.y, reference.punto.z)
            node.renderingOrder = 1200
            revisionePianiNode.addChildNode(node)
        }
    }

    /// Assegna i triangoli pennellati alla faccia attiva (e li toglie dalle altre).
    func assegnaAFacciaAttiva(_ idx: Set<Int>) {
        guard let fid = facciaAttivaId,
              let i = facce.firstIndex(where: { $0.id == fid }) else { return }
        var cambiato = false
        for j in facce.indices where j != i {
            let prima = facce[j].triangoli.count
            facce[j].triangoli.subtract(idx)
            if facce[j].triangoli.count != prima { cambiato = true }
        }
        let prima = facce[i].triangoli.count
        facce[i].triangoli.formUnion(idx)
        if facce[i].triangoli.count != prima { cambiato = true }
        if cambiato { ridisegnaFacce() }
    }

    func aggiungiSelezioneAlLayerAttivo() {
        guard !selezione.isEmpty else { return }
        if facciaAttivaId == nil { nuovaFaccia() }
        registraUndo()
        assegnaAFacciaAttiva(selezione)
        deselezionaTutto()
    }

    func rinominaFaccia(_ id: Int, _ nome: String) {
        guard let i = facce.firstIndex(where: { $0.id == id }) else { return }
        facce[i].nome = nome
    }

    func cambiaTipoFaccia(_ id: Int, _ tipo: TipoFaccia) {
        guard let i = facce.firstIndex(where: { $0.id == id }) else { return }
        facce[i].tipo = tipo
    }

    func cambiaPrioritaFaccia(_ id: Int, _ priorita: Int) {
        guard let i = facce.firstIndex(where: { $0.id == id }) else { return }
        facce[i].priorita = max(0, priorita)
    }

    func eliminaFaccia(_ id: Int) {
        registraUndo()
        facce.removeAll { $0.id == id }
        if facciaAttivaId == id { facciaAttivaId = facce.last?.id }
        // togli ogni riferimento residuo alla faccia eliminata
        facceSelezionate.remove(id)
        selFacceAllinea.remove(id)
        // ridisegna SIA il proxy SIA i quad dei piani: eliminando un piano deve
        // sparire tutto (prima restava il quad perché ridisegnavamo solo le facce).
        ridisegnaFacce()
        ridisegnaPiani()
        aggiornaNumElementi()
    }

    /// Unisce la faccia `sorgente` in `target` (ne assorbe i triangoli) e la rimuove.
    func unisciFacce(target: Int, sorgente: Int) {
        guard target != sorgente,
              let ti = facce.firstIndex(where: { $0.id == target }),
              let si = facce.firstIndex(where: { $0.id == sorgente }) else { return }
        facce[ti].triangoli.formUnion(facce[si].triangoli)
        facce[ti].pianoPunto = nil; facce[ti].pianoNormale = nil; facce[ti].erroreRms = nil
        facce.remove(at: si)
        if facciaAttivaId == sorgente { facciaAttivaId = target }
        ridisegnaFacce()
    }

    /// Genera (fit) il piano di ogni faccia dai triangoli pennellati + errore RMS.
    func generaPiani() {
        var n = 0
        for i in facce.indices {
            if let (p, nrm) = mesh.fitPiano(facce[i].triangoli) {
                facce[i].pianoPunto = p; facce[i].pianoNormale = nrm
                facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p, normale: nrm)
                n += 1
            }
        }
        pianiGenerati = n
        mostraPiani = true
        ridisegnaPiani()
    }

    func generaPianiDaLayer() {
        registraUndo()
        generaPiani()
        stimaGravita()
        classificaPerGravita()
        for f in facce where f.pianoNormale != nil { generaPoligono(perFaccia: f.id) }
        pianiGenerati = facce.filter { $0.pianoNormale != nil }.count
        // Vista "come il NativePoseMeshViewer": mostra i QUAD puliti dei piani sulla
        // mesh grezza, non i triangoli proxy dipinti (i proxy restano un toggle nel
        // menu vista). Così i piani convalidati si leggono come superfici piatte.
        mostraProxy = false
        mostraPiani = true
        ridisegnaFacce()
        ridisegnaPiani()
    }

    /// Fitta solo le facce ancora senza piano (preserva squadratura/offset manuali).
    private func assicuraPiani() {
        for i in facce.indices where facce[i].pianoNormale == nil {
            if let (p, nrm) = mesh.fitPiano(facce[i].triangoli) {
                facce[i].pianoPunto = p; facce[i].pianoNormale = nrm
                facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p, normale: nrm)
            }
        }
    }

    // MARK: Rifinitura piani — squadratura/snap/offset (§6 a livello proxy)

    /// Assi di riferimento: del piano base se c'è, altrimenti assi mondo.
    private var assiRif: (r: SIMD3<Float>, u: SIMD3<Float>, n: SIMD3<Float>) {
        haPianoBase ? (pianoBaseRight, pianoBaseUp, pianoBaseNormale)
                    : (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
    }

    private func aggiornaNormaleFaccia(_ id: Int, _ nuova: SIMD3<Float>) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              let p = facce[i].pianoPunto else { return }
        let n = simd_normalize(nuova)
        facce[i].pianoNormale = n
        facce[i].erroreRms = mesh.rmsDalPiano(facce[i].triangoli, punto: p, normale: n)
        ridisegnaPiani()
    }

    /// Squadra: aggancia la normale all'asse di riferimento più vicino.
    func squadraPiano(_ id: Int) {
        guard let f = facce.first(where: { $0.id == id }), let n = f.pianoNormale else { return }
        let a = assiRif
        let cand = [a.r, -a.r, a.u, -a.u, a.n, -a.n]
        let best = cand.max(by: { simd_dot(n, $0) < simd_dot(n, $1) }) ?? n
        aggiornaNormaleFaccia(id, best)
    }

    /// Faccia verticale: normale orizzontale (⟂ all'asse "up").
    func pianoVerticale(_ id: Int) {
        guard let f = facce.first(where: { $0.id == id }), let n = f.pianoNormale else { return }
        let u = assiRif.u
        let proj = n - simd_dot(n, u) * u
        if simd_length(proj) > 1e-4 { aggiornaNormaleFaccia(id, proj) }
    }

    /// Faccia orizzontale (davanzale/cornicione): normale = asse "up".
    func pianoOrizzontale(_ id: Int) {
        guard let f = facce.first(where: { $0.id == id }), let n = f.pianoNormale else { return }
        let u = assiRif.u
        aggiornaNormaleFaccia(id, simd_dot(n, u) >= 0 ? u : -u)
    }

    /// Offset del piano lungo la sua normale (rientro/rilievo), step = ‰ del lato.
    func offsetPiano(_ id: Int, verso: Float) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              let p = facce[i].pianoPunto, let n = facce[i].pianoNormale else { return }
        facce[i].pianoPunto = p + n * (estensioneMesh * 0.005 * verso)
        ridisegnaPiani()
    }

    /// Regola l'altezza del poligono: sposta la CIMA (cima=true) o la BASE
    /// (cima=false) lungo la gravità → alza/abbassa il bordo alto/basso delle facciate.
    func regolaAltezzaFaccia(_ id: Int, cima: Bool, verso: Float) {
        guard let i = facce.firstIndex(where: { $0.id == id }),
              var poly = facce[i].poligono, poly.count >= 3 else { return }
        let su = simd_normalize(gravitaSu)
        let proj = poly.map { simd_dot($0, su) }
        guard let lo = proj.min(), let hi = proj.max(), hi > lo else { return }
        let mid = (lo + hi) * 0.5
        let step = su * (estensioneMesh * 0.02 * verso)
        registraUndo()
        for k in poly.indices where (proj[k] >= mid) == cima { poly[k] += step }
        facce[i].poligono = poly
        facce[i].pianoPunto = poly.reduce(SIMD3<Float>(0, 0, 0), +) / Float(poly.count)
        ridisegnaPiani()
    }

    /// Quad colorato per ogni piano fittato (anteprima multipiano proxy).
    private func ridisegnaPiani() {
        pianiNode.childNodes.forEach { $0.removeFromParentNode() }
        let visibili = mostraPiani && !mostraSviluppoPiani
        pianiNode.isHidden = !visibili
        guard visibili else { return }
        let upRef = assiRif.u
        for f in facce {
            if f.nascosto { continue }
            guard let n = f.pianoNormale else { continue }
            // Poligono editabile se presente (anche per facciate estruse senza
            // triangoli); altrimenti bbox del piano dai triangoli pennellati.
            let pts3: [SIMD3<Float>]
            if let poly = f.poligono, poly.count >= 3 {
                pts3 = poly
            } else if let o = f.pianoPunto, !f.triangoli.isEmpty {
                var right = simd_cross(upRef, n)
                if simd_length(right) < 1e-4 { right = simd_cross(SIMD3(1, 0, 0), n) }
                right = simd_normalize(right)
                let up = simd_normalize(simd_cross(n, right))
                var uMin = Float.greatestFiniteMagnitude, uMax = -Float.greatestFiniteMagnitude
                var wMin = Float.greatestFiniteMagnitude, wMax = -Float.greatestFiniteMagnitude
                for ti in f.triangoli {
                    let t = mesh.triangles[ti]
                    for v in [mesh.vertices[Int(t.x)], mesh.vertices[Int(t.y)], mesh.vertices[Int(t.z)]] {
                        let d = v - o
                        let u = simd_dot(d, right), w = simd_dot(d, up)
                        uMin = min(uMin, u); uMax = max(uMax, u); wMin = min(wMin, w); wMax = max(wMax, w)
                    }
                }
                guard uMax > uMin else { continue }
                pts3 = [o + right * uMin + up * wMin, o + right * uMax + up * wMin,
                        o + right * uMax + up * wMax, o + right * uMin + up * wMax]
            } else { continue }
            let corners = pts3.map { SCNVector3($0.x, $0.y, $0.z) }
            // riempimento a ventaglio (poligoni convessi)
            var idx: [Int32] = []
            for k in 1..<(corners.count - 1) { idx += [0, Int32(k), Int32(k + 1)] }
            let src = SCNGeometrySource(vertices: corners)
            let elem = SCNGeometryElement(indices: idx, primitiveType: .triangles)
            let g = SCNGeometry(sources: [src], elements: [elem])
            // Pieno & opaco quando si guardano SOLO i piani (geometria/texture nascoste),
            // così il piano si legge come una superficie solida; semi-trasparente quando
            // è sovrapposto alla mesh (per non coprirla). Con i piani pieni si scrive sul
            // depth → si occludono correttamente fra loro.
            let soloPiani = !mostraMesh && !mostraTexturaOC
            let m = SCNMaterial()
            let faSel = strumento == .allinea && facciaAllineaSelezionata(f.id)
            m.isDoubleSided = true
            m.lightingModel = .constant
            if haPianiTexturizzati {
                // Il quad resta disponibile all'hit-test, ma non compete nel
                // depth buffer con la stessa superficie texturizzata.
                m.diffuse.contents = UIColor.clear
                m.colorBufferWriteMask = []
                m.readsFromDepthBuffer = false
                m.writesToDepthBuffer = false
            } else {
                m.diffuse.contents = faSel ? UIColor.systemOrange.withAlphaComponent(0.6)
                    : f.colore.withAlphaComponent(soloPiani ? 1.0 : 0.62)
                m.writesToDepthBuffer = soloPiani
            }
            g.materials = [m]
            let fill = SCNNode(geometry: g)
            fill.name = "piano:\(f.id)"   // selezionabile col tap (anche piani solo-poligono)
            pianiNode.addChildNode(fill)
            if let c = MeshFactory.lineaGeometria(corners, colore: f.colore, chiusa: true) {
                pianiNode.addChildNode(SCNNode(geometry: c))
            }
            // Maniglie (solo sul poligono editabile della faccia attiva):
            // sfere bianche = angoli (Fase C drag), cubetti arancioni = edge
            // (trascina lato / tocca per splittare).
            let inAllinea = strumento == .allinea
            if f.poligono != nil, facceAttiveSet.contains(f.id) || inAllinea {
                let r = max(CGFloat(estensioneMesh) * 0.006, 0.006)
                let presaR = r * 3.0
                for (k, c) in corners.enumerated() {
                    let s = SCNSphere(radius: r); s.segmentCount = 12
                    let sm = SCNMaterial()
                    sm.diffuse.contents = (inAllinea && verticeEvidenziato(faccia: f.id, k: k)) ? UIColor.systemOrange : UIColor.white
                    sm.lightingModel = .constant
                    sm.readsFromDepthBuffer = false; sm.writesToDepthBuffer = false
                    s.materials = [sm]
                    let node = SCNNode(geometry: s)
                    node.position = c
                    node.renderingOrder = 1000   // sempre sopra la mesh opaca
                    node.name = "maniglia:\(f.id):\(k)"
                    let presa = SCNNode(geometry: SCNSphere(radius: presaR))
                    let pm = SCNMaterial(); pm.diffuse.contents = UIColor.white.withAlphaComponent(0.01)
                    pm.transparency = 0.01; pm.lightingModel = .constant
                    pm.readsFromDepthBuffer = false; pm.writesToDepthBuffer = false
                    presa.geometry?.materials = [pm]
                    presa.name = node.name
                    node.addChildNode(presa)
                    pianiNode.addChildNode(node)
                }
                for k in corners.indices {
                    let a = pts3[k], b = pts3[(k + 1) % pts3.count]
                    let mid = (a + b) * 0.5
                    let box = SCNBox(width: r * 1.8, height: r * 1.8, length: r * 0.8, chamferRadius: r * 0.25)
                    let bm = SCNMaterial()
                    bm.diffuse.contents = (inAllinea && spigoloEvidenziato(faccia: f.id, k: k)) ? UIColor.systemOrange : UIColor(EditorTheme.accento)
                    bm.lightingModel = .constant
                    bm.readsFromDepthBuffer = false; bm.writesToDepthBuffer = false
                    box.materials = [bm]
                    let node = SCNNode(geometry: box)
                    node.position = SCNVector3(mid.x, mid.y, mid.z)
                    node.renderingOrder = 1000
                    node.name = "edge:\(f.id):\(k)"
                    let presa = SCNNode(geometry: SCNSphere(radius: presaR))
                    let pm = SCNMaterial(); pm.diffuse.contents = UIColor.white.withAlphaComponent(0.01)
                    pm.transparency = 0.01; pm.lightingModel = .constant
                    pm.readsFromDepthBuffer = false; pm.writesToDepthBuffer = false
                    presa.geometry?.materials = [pm]
                    presa.name = node.name
                    node.addChildNode(presa)
                    pianiNode.addChildNode(node)
                }
            }
        }
        if let centro = centroManigliaPoligonoAttiva() {
            aggiungiGizmoAssiPoligono(centro: centro)
        }
    }

    private func centroManigliaPoligonoAttiva() -> SIMD3<Float>? {
        guard let h = manigliaPoligonoAttiva,
              let poly = facce.first(where: { $0.id == h.faccia })?.poligono,
              h.indice >= 0, h.indice < poly.count else { return nil }
        if h.edge {
            return (poly[h.indice] + poly[(h.indice + 1) % poly.count]) * 0.5
        }
        return poly[h.indice]
    }

    private func aggiungiGizmoAssiPoligono(centro: SIMD3<Float>) {
        let len = max(estensioneMesh * 0.085, 0.04)
        let frame = assiMovimentoPoligono(faccia: manigliaPoligonoAttiva?.faccia)
        let assi: [(AsseMovimentoPoligono, SIMD3<Float>, UIColor)] = [
            (.x, frame.r, UIColor(red: 1.0, green: 0.22, blue: 0.18, alpha: 1)),
            (.y, frame.u, UIColor(red: 0.20, green: 0.85, blue: 0.35, alpha: 1)),
            (.z, frame.n, UIColor(red: 0.20, green: 0.48, blue: 1.0, alpha: 1)),
        ]
        for (asse, dir, colore) in assi {
            let attivo = asseMovimentoPoligono == asse
            let a = centro - dir * (len * 0.22)
            let b = centro + dir * len
            let v = [SCNVector3(a.x, a.y, a.z), SCNVector3(b.x, b.y, b.z)]
            if let g = MeshFactory.lineaGeometria(v, colore: colore.withAlphaComponent(attivo ? 1 : 0.72), chiusa: false) {
                let n = SCNNode(geometry: g)
                n.renderingOrder = 1100
                pianiNode.addChildNode(n)
            }
            let tip = SCNSphere(radius: CGFloat(len) * (attivo ? 0.055 : 0.04))
            let m = SCNMaterial()
            m.diffuse.contents = colore
            m.lightingModel = .constant
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            tip.materials = [m]
            let node = SCNNode(geometry: tip)
            let p = centro + dir * len
            node.position = SCNVector3(p.x, p.y, p.z)
            node.renderingOrder = 1100
            pianiNode.addChildNode(node)
        }
    }

    // MARK: Validazione (§8)

    private func mostraFaccia(_ f: FacciaProxy) -> Bool {
        if f.nascosto { return false }
        switch vistaValidazione {
        case .normale, .soloProxy: return true
        case .soloAccettate:       return f.tipo != .scarto
        case .soloScarti:          return f.tipo == .scarto
        }
    }

    /// Applica la vista corrente: trasparenza mesh + visibilità overlay proxy +
    /// mostra/nascondi la geometria OC grigia e la versione texturizzata OC.
    private func aggiornaVista() {
        let t: CGFloat = vistaValidazione == .soloProxy ? 0.04
            : (vistaValidazione == .soloScarti ? 0.18 : 1.0)
        // geometria grigia nascosta se l'utente la spegne o se mostra la texture
        let mostraGrigia = mostraMesh && !mostraTexturaOC && !mostraSviluppoPiani
        contentNode.geometry?.firstMaterial?.transparency = mostraGrigia ? t : 0
        ocTextureNode?.isHidden = !mostraTexturaOC || mostraSviluppoPiani
        facceProxyNode.isHidden = !mostraProxy || mostraSviluppoPiani
        ridisegnaFacce()
        ridisegnaPiani()   // i piani diventano pieni/trasparenti secondo la visibilità mesh
    }

    /// Riallinea triangoli e piani dopo un taglio. Conserva la normale
    /// architettonica rilevata, aggiornando offset e perimetro sulla mesh residua.
    private func rimappaFacce(_ remap: [Int]) {
        guard !facce.isEmpty else { return }
        for i in facce.indices {
            let avevaSupporto = !facce[i].triangoli.isEmpty
            facce[i].triangoli = Set(facce[i].triangoli.compactMap {
                remap.indices.contains($0) && remap[$0] >= 0 ? remap[$0] : nil
            })

            // Alcuni detector producono soltanto piano e poligono. In quel caso
            // ricava il supporto dalla geometria residua. Se invece il supporto
            // esisteva ed e' stato tagliato interamente, il piano va eliminato.
            if !avevaSupporto, facce[i].triangoli.isEmpty {
                facce[i].triangoli = trovaSupportoPiano(facce[i])
            }

            guard !facce[i].triangoli.isEmpty else { continue }
            if let normal0 = facce[i].pianoNormale,
               let point0 = facce[i].pianoPunto {
                let normal = simd_normalize(normal0)
                var offset: Float = 0
                for triangleIndex in facce[i].triangoli {
                    offset += simd_dot(
                        mesh.centroid(mesh.triangles[triangleIndex]) - point0, normal)
                }
                offset /= Float(facce[i].triangoli.count)
                let point = point0 + normal * offset
                facce[i].pianoPunto = point
                facce[i].pianoNormale = normal
                facce[i].erroreRms = mesh.rmsDalPiano(
                    facce[i].triangoli, punto: point, normale: normal)
            } else if let (point, normal) = mesh.fitPiano(facce[i].triangoli) {
                facce[i].pianoPunto = point
                facce[i].pianoNormale = normal
                facce[i].erroreRms = mesh.rmsDalPiano(
                    facce[i].triangoli, punto: point, normale: normal)
            }
        }
        facce.removeAll { $0.triangoli.isEmpty }
        let validIDs = Set(facce.map(\.id))
        facceSelezionate.formIntersection(validIDs)
        if facciaAttivaId == nil || !facce.contains(where: { $0.id == facciaAttivaId }) {
            facciaAttivaId = facce.last?.id
        }
        for id in facce.map(\.id) { generaPoligono(perFaccia: id) }
        pianiGenerati = facce.filter { $0.pianoNormale != nil }.count
        ridisegnaFacce()
        ridisegnaPiani()
    }

    /// Interseca esattamente i poligoni dei piani con il box orientato. Il
    /// supporto sui triangoli evita piani obsoleti; questo passaggio elimina
    /// anche il piccolo sbordo dovuto al rettangolo/percentili del detector.
    private func ritagliaPianiAlBox() {
        func clip(
            _ input: [SIMD3<Float>],
            axis: Int,
            boundary: Float,
            keepGreater: Bool
        ) -> [SIMD3<Float>] {
            guard let last = input.last else { return [] }
            var output: [SIMD3<Float>] = []
            var previous = last
            var previousInside = keepGreater
                ? previous[axis] >= boundary
                : previous[axis] <= boundary
            for current in input {
                let currentInside = keepGreater
                    ? current[axis] >= boundary
                    : current[axis] <= boundary
                if currentInside != previousInside {
                    let denominator = current[axis] - previous[axis]
                    if abs(denominator) > 1e-8 {
                        let t = (boundary - previous[axis]) / denominator
                        output.append(previous + (current - previous) * t)
                    }
                }
                if currentInside { output.append(current) }
                previous = current
                previousInside = currentInside
            }
            return output
        }

        let worldToBox = boxRot.transpose
        var removed: Set<Int> = []
        for i in facce.indices {
            guard let polygon = facce[i].poligono, polygon.count >= 3 else { continue }
            var local = polygon.map { worldToBox * ($0 - frameOrigin) }
            for axis in 0..<3 {
                local = clip(local, axis: axis, boundary: boxLo[axis], keepGreater: true)
                local = clip(local, axis: axis, boundary: boxHi[axis], keepGreater: false)
                if local.count < 3 { break }
            }
            if local.count >= 3 {
                facce[i].poligono = local.map { frameOrigin + boxRot * $0 }
            } else {
                removed.insert(facce[i].id)
            }
        }
        guard !removed.isEmpty else { return }
        facce.removeAll { removed.contains($0.id) }
        facceSelezionate.subtract(removed)
        if let active = facciaAttivaId, removed.contains(active) {
            facciaAttivaId = facce.last?.id
        }
        pianiGenerati = facce.filter { $0.pianoNormale != nil }.count
    }

    /// Trova i triangoli della mesh residua appartenenti a un piano descritto
    /// solo da normale e poligono (risultati backend privi di indici).
    private func trovaSupportoPiano(_ face: FacciaProxy) -> Set<Int> {
        guard let point = face.pianoPunto,
              let normal0 = face.pianoNormale,
              let polygon = face.poligono,
              polygon.count >= 3 else { return [] }
        let normal = simd_normalize(normal0)
        var right = simd_cross(gravitaSu, normal)
        if simd_length(right) < 1e-5 {
            right = simd_cross(SIMD3<Float>(1, 0, 0), normal)
        }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(normal, right))
        let polygon2D = polygon.map { p in
            SIMD2<Float>(simd_dot(p - point, right), simd_dot(p - point, up))
        }
        let tolerance = max(estensioneMesh * 0.012, 1e-4)
        let cosNormal = cos(35 * Float.pi / 180)

        func contiene(_ p: SIMD2<Float>) -> Bool {
            var inside = false
            var j = polygon2D.count - 1
            for i in polygon2D.indices {
                let a = polygon2D[i]
                let b = polygon2D[j]
                if (a.y > p.y) != (b.y > p.y) {
                    let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                    if p.x < x { inside.toggle() }
                }
                j = i
            }
            return inside
        }

        var support: Set<Int> = []
        for triangleIndex in mesh.triangles.indices {
            let center = mesh.centroid(mesh.triangles[triangleIndex])
            guard abs(simd_dot(center - point, normal)) <= tolerance,
                  abs(simd_dot(mesh.normale(triangleIndex), normal)) >= cosNormal else { continue }
            let p2 = SIMD2<Float>(
                simd_dot(center - point, right),
                simd_dot(center - point, up))
            if contiene(p2) { support.insert(triangleIndex) }
        }
        return support
    }

    /// Ricostruisce l'overlay colorato delle facce (una geometria per faccia).
    private func ridisegnaFacce() {
        facceProxyNode.childNodes.forEach { $0.removeFromParentNode() }
        guard !mostraSviluppoPiani else { return }
        for f in facce where mostraFaccia(f) {
            guard let g = mesh.selezioneGeometry(f.triangoli, colore: f.colore.withAlphaComponent(0.6)) else { continue }
            facceProxyNode.addChildNode(SCNNode(geometry: g))
        }
    }

    // MARK: Esportazione proxy (§9)

    @Published var statoProxy: StatoProxy = .corretto

    /// Scrive `proxy_overrides.json` (override manuali completi, triangoli inclusi)
    /// e `multipiano_proxy.json` (solo piani per il bake) in temp; ritorna gli URL.
    func esportaProxy(nomeBase: String) -> [URL] {
        assicuraPiani()   // fitta SOLO i piani mancanti (non tocca le rifiniture)
        let pb: PianoBaseJSON? = haPianoBase ? PianoBaseJSON(
            origine: pianoBaseOrigine.lista, normale: pianoBaseNormale.lista,
            right: pianoBaseRight.lista, up: pianoBaseUp.lista) : nil

        let overrides = ProxyOverridesJSON(
            versione: 1, stato: statoProxy.raw,
            mesh: MeshInfoJSON(vertici: mesh.vertexCount, triangoli: mesh.triangleCount),
            piano_base: pb,
            facce: facce.map { f in
                FacciaOverrideJSON(
                    id: f.id, nome: f.nome, tipo: f.tipo.rawValue, colore: f.coloreHex,
                    priorita: f.priorita, n_triangoli: f.triangoli.count,
                    triangoli: f.triangoli.sorted(),
                    piano: f.pianoPunto.flatMap { p in f.pianoNormale.map {
                        PianoJSON(punto: p.lista, normale: $0.lista) } })
            })

        let multipiano = MultipianoJSON(
            versione: 1, stato: statoProxy.raw, piano_base: pb,
            piani: facce.compactMap { f in
                guard let p = f.pianoPunto, let n = f.pianoNormale else { return nil }
                return PianoProxyJSON(id: f.id, nome: f.nome, tipo: f.tipo.rawValue,
                                      priorita: f.priorita, punto: p.lista, normale: n.lista)
            })

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var urls: [URL] = []
        let dir = FileManager.default.temporaryDirectory
        if let d = try? enc.encode(overrides) {
            let u = dir.appendingPathComponent("\(nomeBase)_proxy_overrides.json")
            if (try? d.write(to: u, options: .atomic)) != nil { urls.append(u) }
        }
        if let d = try? enc.encode(multipiano) {
            let u = dir.appendingPathComponent("\(nomeBase)_multipiano_proxy.json")
            if (try? d.write(to: u, options: .atomic)) != nil { urls.append(u) }
        }
        return urls
    }

    /// Serializza i piani decisi (facce con piano fittato + piano_base) nel
    /// documento da caricare sul backend per la proiezione. `nil` se non c'è
    /// nessun piano valido. Include i triangoli per la maschera sulla mesh pulita.
    func esportaPianiPayload(includiVuoto: Bool = false) -> Data? {
        assicuraPiani()   // fitta i piani mancanti senza toccare le rifiniture
        for f in facce where f.poligono == nil && !f.triangoli.isEmpty {
            generaPoligono(perFaccia: f.id)
        }
        let pb: PianoBaseJSON? = haPianoBase ? PianoBaseJSON(
            origine: pianoBaseOrigine.lista, normale: pianoBaseNormale.lista,
            right: pianoBaseRight.lista, up: pianoBaseUp.lista) : nil
        let planes: [PianoUploadJSON] = facce.compactMap { f in
            guard let p = f.pianoPunto, let n = f.pianoNormale,
                  let polygon = f.poligono, polygon.count >= 3 else { return nil }
            return PianoUploadJSON(
                id: f.id, nome: f.nome, tipo: f.tipo.rawValue, priorita: f.priorita,
                punto: p.lista, normale: n.lista, corners: polygon.map(\.lista),
                n_triangoli: f.triangoli.count, triangoli: f.triangoli.sorted())
        }
        guard includiVuoto || !planes.isEmpty else { return nil }
        let doc = PianiUploadDoc(schema: "acro.planes/v1", versione: 1,
                                 stato: statoProxy.raw, piano_base: pb, planes: planes)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(doc)
    }

    func esportaMeshRipulita(nomeBase: String) -> [URL] {
        guard mesh.vertexCount > 0, mesh.triangleCount > 0 else { return [] }
        let nomePulito = nomeBase
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return [] }
        let dir = docs.appendingPathComponent("MeshExport", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(nomePulito)_mesh_ripulita.obj")
            var testo = ""
            testo.reserveCapacity(mesh.vertexCount * 36 + mesh.triangleCount * 24)
            testo += "# Acrobatica mesh ripulita\n"
            testo += "# vertici \(mesh.vertexCount), triangoli \(mesh.triangleCount)\n"
            for v in mesh.vertices {
                testo += String(format: "v %.7g %.7g %.7g\n",
                                locale: Locale(identifier: "en_US_POSIX"),
                                v.x, v.y, v.z)
            }
            for t in mesh.triangles {
                testo += "f \(Int(t.x) + 1) \(Int(t.y) + 1) \(Int(t.z) + 1)\n"
            }
            try testo.write(to: url, atomically: true, encoding: .utf8)
            cursoreInfo = "Mesh salvata: \(url.lastPathComponent)"
            return [url]
        } catch {
            self.errore = "Salvataggio mesh fallito: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: Creazione faccia per punti (Fase 2)

    /// Aggiunge un vertice della faccia in costruzione (punto sulla superficie
    /// della mesh, già in world space dall'hit-test). Chiamato dal tap.
    func aggiungiPunto(_ p: SCNVector3) {
        guard strumento == .punti else { return }
        puntiFaccia.append(p)
        numPuntiFaccia = puntiFaccia.count
        ridisegnaPunti()
    }

    func rimuoviUltimoPunto() {
        guard !puntiFaccia.isEmpty else { return }
        puntiFaccia.removeLast()
        numPuntiFaccia = puntiFaccia.count
        ridisegnaPunti()
    }

    func annullaFaccia() {
        puntiFaccia.removeAll()
        numPuntiFaccia = 0
        ridisegnaPunti()
    }

    /// §4 — Calcola il piano livello-zero dai punti toccati (≥3): fit PCA →
    /// origine (centroide) + normale + assi nel piano, e lo visualizza.
    func calcolaPianoBase() {
        guard puntiFaccia.count >= 3 else { return }
        let pts = puntiFaccia.map { SIMD3<Float>($0.x, $0.y, $0.z) }
        var mean = SIMD3<Double>(repeating: 0)
        for p in pts { mean += SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) }
        mean /= Double(pts.count)
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in pts {
            let d = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) - mean
            cov[0][0] += d.x * d.x; cov[0][1] += d.x * d.y; cov[0][2] += d.x * d.z
            cov[1][1] += d.y * d.y; cov[1][2] += d.y * d.z; cov[2][2] += d.z * d.z
        }
        cov[1][0] = cov[0][1]; cov[2][0] = cov[0][2]; cov[2][1] = cov[1][2]
        let (_, vecs) = EditableMesh.eigenSym3(cov)
        let n = simd_normalize(SIMD3<Float>(Float(vecs[0][2]), Float(vecs[1][2]), Float(vecs[2][2])))

        pianoBaseOrigine = SIMD3(Float(mean.x), Float(mean.y), Float(mean.z))
        pianoBaseNormale = n
        // Assi nel piano: right ⟂ n usando un riferimento non parallelo.
        let rif: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        pianoBaseRight = simd_normalize(simd_cross(rif, n))
        pianoBaseUp = simd_normalize(simd_cross(n, pianoBaseRight))
        haPianoBase = true
        renderPianoBase()
        annullaFaccia()
    }

    private func renderPianoBase() {
        pianoBaseNode.childNodes.forEach { $0.removeFromParentNode() }
        pianoBaseNode.geometry = nil
        guard haPianoBase else { return }
        let hs = max(estensioneMesh * 0.6, 0.5)
        let o = pianoBaseOrigine
        let r = pianoBaseRight * hs, u = pianoBaseUp * hs
        let corners = [o - r - u, o + r - u, o + r + u, o - r + u].map { SCNVector3($0.x, $0.y, $0.z) }
        let src = SCNGeometrySource(vertices: corners)
        let elem = SCNGeometryElement(indices: [Int32](arrayLiteral: 0, 1, 2, 0, 2, 3), primitiveType: .triangles)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(EditorTheme.accento).withAlphaComponent(0.22)
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        g.materials = [m]
        pianoBaseNode.geometry = g
        // Contorno del piano.
        if let c = MeshFactory.lineaGeometria(corners, colore: UIColor(EditorTheme.accento), chiusa: true) {
            pianoBaseNode.addChildNode(SCNNode(geometry: c))
        }
    }

    /// Allinea il box di lavoro al piano livello-zero (asse z = normale).
    func allineaBoxAlPianoBase() {
        guard haPianoBase else { return }
        boxRot = simd_float3x3(pianoBaseRight, pianoBaseUp, pianoBaseNormale)
        frameOrigin = pianoBaseOrigine
        let rt = boxRot.transpose
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices { let l = rt * (v - frameOrigin); lo = simd_min(lo, l); hi = simd_max(hi, l) }
        let margine = (hi - lo) * 0.02
        boxLo = lo - margine; boxHi = hi + margine
        ricostruisciBox()
    }

    /// Ricostruisce sfere + polilinea dei punti in corso.
    private func ridisegnaPunti() {
        markersNode.childNodes
            .filter { $0 !== lineNode }
            .forEach { $0.removeFromParentNode() }
        for p in puntiFaccia {
            let s = SCNNode(geometry: SCNSphere(radius: raggioMarker))
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(EditorTheme.accento)
            m.lightingModel = .constant
            s.geometry?.materials = [m]
            s.position = p
            markersNode.addChildNode(s)
        }
        lineNode.geometry = MeshFactory.lineaGeometria(
            puntiFaccia, colore: UIColor(EditorTheme.accento), chiusa: false)
    }
}

// MARK: – Fabbrica mesh procedurale (test bed editabile)

enum MeshFactory {
    /// Polilinea (aperta o chiusa) che collega i punti — contorno della faccia.
    static func lineaGeometria(_ pts: [SCNVector3], colore: UIColor,
                               chiusa: Bool) -> SCNGeometry? {
        guard pts.count >= 2 else { return nil }
        var indici: [Int32] = []
        for i in 0..<(pts.count - 1) { indici += [Int32(i), Int32(i + 1)] }
        if chiusa, pts.count >= 3 { indici += [Int32(pts.count - 1), 0] }
        let src = SCNGeometrySource(vertices: pts)
        let elem = SCNGeometryElement(indices: indici, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.lightingModel = .constant
        g.materials = [m]
        return g
    }

    /// Wireframe (12 spigoli) di un box assi-allineato lo..hi.
    static func boxWireframe(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>,
                             colore: UIColor) -> SCNGeometry {
        let c: [SCNVector3] = [
            SCNVector3(lo.x, lo.y, lo.z), SCNVector3(hi.x, lo.y, lo.z),
            SCNVector3(hi.x, hi.y, lo.z), SCNVector3(lo.x, hi.y, lo.z),
            SCNVector3(lo.x, lo.y, hi.z), SCNVector3(hi.x, lo.y, hi.z),
            SCNVector3(hi.x, hi.y, hi.z), SCNVector3(lo.x, hi.y, hi.z),
        ]
        let e: [Int32] = [0,1, 1,2, 2,3, 3,0,  4,5, 5,6, 6,7, 7,4,  0,4, 1,5, 2,6, 3,7]
        let src = SCNGeometrySource(vertices: c)
        let elem = SCNGeometryElement(indices: e, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false   // il box resta visibile sopra la mesh
        g.materials = [m]
        return g
    }

    /// Croce 3D (mirino) di semilato R, lungo i 3 assi.
    static func croce3D(_ R: Float, colore: UIColor) -> SCNGeometry {
        let v: [SCNVector3] = [
            SCNVector3(-R, 0, 0), SCNVector3(R, 0, 0),
            SCNVector3(0, -R, 0), SCNVector3(0, R, 0),
            SCNVector3(0, 0, -R), SCNVector3(0, 0, R),
        ]
        let src = SCNGeometrySource(vertices: v)
        let elem = SCNGeometryElement(indices: [Int32](arrayLiteral: 0, 1, 2, 3, 4, 5), primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false   // sempre visibile sopra la mesh
        g.materials = [m]
        return g
    }

    /// Poligono pieno (triangolazione a ventaglio) — la faccia della facciata.
    static func facciaGeometria(_ pts: [SCNVector3], colore: UIColor) -> SCNGeometry? {
        guard pts.count >= 3 else { return nil }
        var idx: [Int32] = []
        for i in 1..<(pts.count - 1) { idx += [0, Int32(i), Int32(i + 1)] }
        let src = SCNGeometrySource(vertices: pts)
        let elem = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        let g = SCNGeometry(sources: [src], elements: [elem])
        let m = SCNMaterial()
        m.diffuse.contents = colore
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.writesToDepthBuffer = false        // evita z-fighting col muro sottostante
        g.materials = [m]
        return g
    }

    /// Facciata demo: muro suddiviso + balcone sporgente + triangoli sparsi
    /// (rumore da ripulire). Mesh INDICIZZATA singola, così la Fase 3 può
    /// cancellarne i triangoli direttamente dai buffer.
    static func demoMesh() -> EditableMesh {
        var verts: [SIMD3<Float>] = []
        var idx: [UInt32] = []

        // Muro: griglia 12×8 nel piano XY (z=0), 6×4 m.
        let cols = 12, rows = 8
        let W: Float = 6, H: Float = 4
        let base = UInt32(verts.count)
        for r in 0...rows {
            for c in 0...cols {
                let x = -W / 2 + W * Float(c) / Float(cols)
                let y = -H / 2 + H * Float(r) / Float(rows)
                verts.append(SIMD3(x, y, 0))
            }
        }
        let stride = UInt32(cols + 1)
        for r in 0..<UInt32(rows) {
            for c in 0..<UInt32(cols) {
                let i0 = base + r * stride + c
                let i1 = i0 + 1
                let i2 = i0 + stride
                let i3 = i2 + 1
                idx += [i0, i2, i1, i1, i2, i3]
            }
        }

        // Balcone: scatola sporgente in basso-centro, z∈[0,0.8].
        appendiScatola(&verts, &idx,
                       min: SIMD3(-1.0, -1.9, 0.0), max: SIMD3(1.0, -0.6, 0.8))

        // Rumore: triangoli sparsi staccati dal muro, da ripulire in Fase 3.
        let sparsi: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(3.6, 1.8, 1.4), SIMD3(3.9, 2.1, 1.2), SIMD3(3.4, 2.3, 1.6)),
            (SIMD3(-3.8, -1.2, 2.0), SIMD3(-3.4, -1.0, 2.2), SIMD3(-3.6, -0.7, 1.8)),
            (SIMD3(0.5, 2.6, 2.4), SIMD3(0.9, 2.8, 2.1), SIMD3(0.3, 3.0, 2.6)),
        ]
        for tri in sparsi {
            let b = UInt32(verts.count)
            verts += [tri.0, tri.1, tri.2]
            idx += [b, b + 1, b + 2]
        }

        var tris: [SIMD3<UInt32>] = []
        tris.reserveCapacity(idx.count / 3)
        var k = 0
        while k + 2 < idx.count { tris.append(SIMD3(idx[k], idx[k + 1], idx[k + 2])); k += 3 }
        return EditableMesh(vertices: verts, triangles: tris)
    }

    /// Aggiunge una scatola assi-allineata (12 triangoli) ai buffer.
    private static func appendiScatola(_ verts: inout [SIMD3<Float>],
                                       _ idx: inout [UInt32],
                                       min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        let b = UInt32(verts.count)
        verts += [
            SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z),
            SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z),
            SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z),
            SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z),
        ]
        let f: [UInt32] = [
            0, 1, 2, 0, 2, 3,   // retro (z=lo)
            4, 6, 5, 4, 7, 6,   // fronte (z=hi)
            0, 4, 5, 0, 5, 1,   // basso
            3, 2, 6, 3, 6, 7,   // alto
            0, 3, 7, 0, 7, 4,   // sinistra
            1, 5, 6, 1, 6, 2,   // destra
        ]
        idx += f.map { b + $0 }
    }

    /// Costruisce una `SCNGeometry` indicizzata con normali per-vertice calcolate.
    static func geometria(da verts: [SIMD3<Float>], indici: [UInt32],
                          colore: UIColor) -> SCNGeometry {
        // Normali: media delle normali delle facce incidenti.
        var normals = [SIMD3<Float>](repeating: .zero, count: verts.count)
        var i = 0
        while i + 2 < indici.count {
            let a = Int(indici[i]), b = Int(indici[i + 1]), c = Int(indici[i + 2])
            let n = cross(verts[b] - verts[a], verts[c] - verts[a])
            normals[a] += n; normals[b] += n; normals[c] += n
            i += 3
        }
        normals = normals.map { simd_length($0) > 1e-6 ? simd_normalize($0) : SIMD3(0, 0, 1) }

        let vData = verts.withUnsafeBytes { Data($0) }
        let nData = normals.withUnsafeBytes { Data($0) }
        let st = MemoryLayout<SIMD3<Float>>.stride   // 16 (padded): SceneKit salta il pad

        let vSrc = SCNGeometrySource(
            data: vData, semantic: .vertex, vectorCount: verts.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: st)
        let nSrc = SCNGeometrySource(
            data: nData, semantic: .normal, vectorCount: normals.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: st)

        let iData = indici.withUnsafeBytes { Data($0) }
        let elem = SCNGeometryElement(
            data: iData, primitiveType: .triangles,
            primitiveCount: indici.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size)

        let geo = SCNGeometry(sources: [vSrc, nSrc], elements: [elem])
        let mat = SCNMaterial()
        mat.diffuse.contents = colore
        mat.isDoubleSided = true            // mesh OC spesso senza winding coerente
        mat.lightingModel = .blinn          // risponde bene a directional+ambient (PBR serve IBL)
        // Lo shader di clip viene attivato solo nello strumento Box: sulla mesh
        // completa costa durante l'orbita anche quando clipOn vale 0.
        mat.setValue(SCNVector3Zero, forKey: "clipLo")
        mat.setValue(SCNVector3Zero, forKey: "clipHi")
        mat.setValue(NSValue(scnMatrix4: SCNMatrix4Identity), forKey: "clipInv")
        mat.setValue(Float(0), forKey: "clipOn")
        geo.materials = [mat]
        return geo
    }

    static let clipModifier = """
    #pragma arguments
    float3 clipLo;
    float3 clipHi;
    float4x4 clipInv;
    float clipOn;
    #pragma body
    if (clipOn > 0.5) {
        float4 wpos = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
        float3 lp = (clipInv * wpos).xyz;
        if (lp.x < clipLo.x || lp.x > clipHi.x ||
            lp.y < clipLo.y || lp.y > clipHi.y ||
            lp.z < clipLo.z || lp.z > clipHi.z) {
            discard_fragment();
        }
    }
    """
}

// MARK: – Caricamento da sessione backend

/// Scarica la mesh della sessione dal backend e apre l'editor 3D.
/// 404 → nessuna mesh caricata dal Mac: mostra messaggio e tasto Chiudi.
struct EditorMesh3DCaricamentoView: View {
    let sessionId: String
    let onChiudi: () -> Void

    @State private var meshFile: URL?
    @State private var textureFile: URL?
    @State private var usaMeshPulita = false
    @State private var errore: String?
    @State private var pronto = false
    @State private var messaggio = "Cerco la mesh salvata…"

    var body: some View {
        Group {
            if pronto {
                EditorMesh3DView(meshFile: meshFile,
                                 textureFile: textureFile,
                                 nome: "Mesh facciata",
                                 sessionId: sessionId,
                                 meshKind: usaMeshPulita ? "clean" : "raw",
                                 consentiAutoPianiAllApertura: usaMeshPulita,
                                 onRipartiDaRaw: {
                                     Task { await ripartiDallaMeshOriginale() }
                                 },
                                 onChiudi: onChiudi)
                    .id("\(meshFile?.path ?? "")-\(usaMeshPulita)")
            } else {
                ZStack {
                    EditorTheme.bg.ignoresSafeArea()
                    VStack(spacing: 12) {
                        if let errore {
                            Text("Mesh non disponibile")
                                .font(Theme.Typo.body(14))
                                .foregroundStyle(Theme.danger)
                            Text(errore)
                                .font(Theme.Typo.caption(11))
                                .foregroundStyle(EditorTheme.testoMuto)
                                .multilineTextAlignment(.center)
                        } else {
                            ProgressView().tint(EditorTheme.accento)
                            Text(messaggio)
                                .font(Theme.Typo.caption())
                                .foregroundStyle(EditorTheme.testoMuto)
                        }
                        Button("Chiudi") { onChiudi() }
                            .foregroundStyle(EditorTheme.accento)
                    }
                    .padding(24)
                }
            }
        }
        .task(id: sessionId) { await carica() }
    }

    @MainActor
    private func ripartiDallaMeshOriginale() async {
        pronto = false
        errore = nil
        messaggio = "Elimino le elaborazioni precedenti…"
        do {
            _ = try await BackendAPIClient.shared.resetDerivedAssets(
                sessionId: sessionId)
            meshFile = nil
            textureFile = nil
            usaMeshPulita = false
            messaggio = "Carico la mesh OC originale…"
            await carica()
        } catch {
            errore = error.localizedDescription
            pronto = true
        }
    }

    private func carica() async {
        // Controlla prima il manifest remoto: una sessione ripristinata alla raw
        // non deve mostrare neppure temporaneamente una vecchia revisione clean.
        // Il bundle resta in cache per checksum, quindi i file invariati non
        // vengono riscaricati.
        messaggio = "Controllo la mesh disponibile…"
        do {
            let clean = try? await BackendAPIClient.shared.fetchMeshInfo(
                sessionId: sessionId, kind: "clean")
            let info: BackendAPIClient.MeshInfoResult
            if let clean, !clean.files.isEmpty {
                info = clean
                usaMeshPulita = true
            } else {
                info = try await BackendAPIClient.shared.fetchMeshInfo(
                    sessionId: sessionId, kind: "raw")
                usaMeshPulita = false
            }
            guard let main = info.main_obj ?? info.files.first else {
                errore = "La sessione non ha una mesh OBJ."
                pronto = true
                return
            }
            messaggio = usaMeshPulita
                ? "Preparo la mesh pulita…"
                : "Preparo la mesh originale…"
            let nuovaMesh = try await BackendAPIClient.shared.downloadMeshFile(
                main, sessionId: sessionId, cacheGroup: "mesh-current")
            var nuovaTexture = textureFile
            // La geometria clean e la texture raw condividono il frame OC. Quando
            // il main e' un OBJ, scarica anche il modello raw come layer visivo.
            if main.name.lowercased().hasSuffix(".obj") {
                if let raw = try? await BackendAPIClient.shared.fetchMeshInfo(
                    sessionId: sessionId, kind: "raw") {
                    if let usdz = raw.files.first(where: {
                        $0.name.lowercased().hasSuffix(".usdz")
                    }) {
                        nuovaTexture = try? await BackendAPIClient.shared.downloadMeshFile(
                            usdz, sessionId: sessionId, cacheGroup: "mesh-raw")
                    } else if let rawOBJ = raw.main_obj ?? raw.files.first(where: {
                        $0.name.lowercased().hasSuffix(".obj")
                    }) {
                        let estensioni = Set(["obj", "mtl", "png", "jpg", "jpeg"])
                        let bundleFiles = raw.files.filter {
                            estensioni.contains(URL(fileURLWithPath: $0.name)
                                .pathExtension.lowercased())
                        }
                        if let bundle = try? await BackendAPIClient.shared
                            .downloadMeshBundle(
                                bundleFiles, sessionId: sessionId,
                                cacheGroup: "mesh-raw") {
                            nuovaTexture = bundle[rawOBJ.name]
                        }
                    }
                }
            }
            meshFile = nuovaMesh
            textureFile = nuovaTexture
            pronto = true
        } catch {
            errore = error.localizedDescription
            pronto = true
        }
    }
}

// MARK: – Preview (mesh demo, nessun asset)

#Preview {
    EditorMesh3DView()
}
