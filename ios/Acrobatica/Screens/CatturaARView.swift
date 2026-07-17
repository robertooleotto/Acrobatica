import SwiftUI
import UIKit
import simd

/// Schermata AR di cattura — versione pulita (redesign).
///
/// Modalità:
///  - **Colonna**: tieni premuto lo scatto → parte la raffica; rilasci → Salva / Rifai
///    la colonna. Ripeti per ogni colonna. La scrematura per gradi avviene nel backend.
///  - **Libera**: tap sullo scatto → singola foto.
///
/// Esposizione: manuale. Punti la luce → tocchi "Blocca". Sblocchi per ri-misurare.
/// Livella: una sola linea centrale (LevelLineOverlay), niente scala "aviazione".
struct CatturaARView: View {
    enum CaptureMode: String, CaseIterable, Identifiable {
        case auto    = "Auto"
        case colonna = "Colonna"
        case libera  = "Libera"
        var id: String { rawValue }
    }

    @ObservedObject var rilievo: Rilievo
    let onCompletato: () -> Void
    let onAnnulla: () -> Void

    @StateObject private var capture = ARFacadeCaptureManager()
    @State private var backendSessionId: String?
    @State private var uploadingCount = 0
    @State private var errorMessage: String?
    @State private var startedAt: Date = .now
    @State private var elapsedTick = 0
    @State private var deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation

    // Stato modalità + raffica colonna
    @State private var mode: CaptureMode = .auto
    @State private var bursting = false
    // Auto (stile RealityScan): scatta su movimento/rotazione.
    @State private var autoRunning = false
    @State private var autoShotCount = 0
    @State private var autoStartIndex = 0       // dove inizia il batch Auto corrente
    @State private var autoNeedsFirstShot = false
    @State private var showCamControls = false
    // Upload in BACKGROUND (sopravvive a standby/crash). La UI legge lo stato qui.
    @ObservedObject private var uploader = BackgroundUploader.shared
    @State private var finishing = false   // schermata di caricamento (camera spenta)
    private let autoMinTranslationM: Float = 0.25   // 25 cm di spostamento
    private let autoMinRotationDeg: Float = 12       // o 12° di rotazione
    @State private var columnStartIndex = 0      // indice frame dove inizia la colonna corrente
    @State private var columnFrameCount = 0
    @State private var columnsSaved = 0
    @State private var reviewingColumn = false   // mostra Salva / Rifai
    @State private var shotThisPress = false      // libera: una foto per pressione
    @State private var lastBurstAt: Date = .distantPast
    @State private var burstFlash = false

    private let burstIntervalSec: TimeInterval = 0.5
    private let scanTimer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZStack {
                ARPreviewView(manager: capture)
                LevelLineOverlay(rollDeg: capture.currentRollDeg)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .ignoresSafeArea()
            .overlay(burstBorder)
            .overlay(flashOverlay)

            if isLandscapeDevice { landscapeChrome } else { portraitChrome }

            if reviewingColumn { reviewPanel }

            if uploader.total > 0 && !finishing {
                VStack { uploadListPanel; Spacer() }
                    .padding(.top, 88)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if finishing { finishingView }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: uploader.total)
        .preferredColorScheme(.dark)
        .onAppear {
            // La cattura compensa da sé la rotazione fisica: l'interfaccia
            // resta portrait anche su iPad (vedi OrientationGate).
            OrientationGate.lock(.portrait)
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateDeviceOrientation(UIDevice.current.orientation)
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            OrientationGate.lock(.all)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateDeviceOrientation(UIDevice.current.orientation)
        }
        .onReceive(timer) { _ in elapsedTick += 1 }
        .onReceive(scanTimer) { _ in Task { await burstTick(); await autoTick() } }
        .alert("Errore", isPresented: Binding(get: { errorMessage != nil },
                                              set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: Orientation helpers

    private var isLandscapeDevice: Bool {
        deviceOrientation == .landscapeLeft || deviceOrientation == .landscapeRight
    }
    private var landscapeToolRotation: Angle {
        switch deviceOrientation {
        case .landscapeLeft: return .degrees(90)
        case .landscapeRight: return .degrees(-90)
        case .portraitUpsideDown: return .degrees(180)
        default: return .zero
        }
    }
    private func updateDeviceOrientation(_ o: UIDeviceOrientation) {
        guard o == .portrait || o == .portraitUpsideDown || o == .landscapeLeft || o == .landscapeRight else { return }
        deviceOrientation = o
    }

    private var elapsedString: String {
        let s = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: Overlays

    @ViewBuilder
    private var burstBorder: some View {
        if bursting {
            RoundedRectangle(cornerRadius: 0)
                .stroke(Theme.danger.opacity(0.95), lineWidth: 5)
                .shadow(color: Theme.danger.opacity(0.8), radius: 16)
                .padding(2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var flashOverlay: some View {
        if burstFlash {
            Color.white.opacity(0.12).allowsHitTesting(false).transition(.opacity)
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            GlassPillButton(systemImage: "xmark") { onAnnulla() }
            Spacer()
            GlassPill {
                Circle().fill(bursting ? Theme.danger : Theme.yellow).frame(width: 8, height: 8)
                Text("\(elapsedString) · \(columnsSaved) col")
                    .font(Theme.Typo.mono(13, .semibold))
            }
            Spacer()
            GlassPill {
                Image(systemName: uploadingCount > 0 ? "icloud.and.arrow.up" : "checkmark.icloud")
                    .foregroundStyle(uploadingCount > 0 ? Theme.warning : Theme.success)
                Text("\(rilievo.frameCatturati.count)")
                    .font(Theme.Typo.mono(13, .semibold))
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    /// Badge esposizione tappabile: punta la luce e blocca / sblocca.
    private var exposureBadge: some View {
        Button { toggleExposureLock() } label: {
            GlassPill {
                Image(systemName: capture.cameraControlsLocked ? "lock.fill" : "camera.metering.center.weighted")
                    .foregroundStyle(capture.cameraControlsLocked ? Theme.success : Theme.yellow)
                Text(capture.cameraControlsLocked ? "Esposizione bloccata · tocca per sbloccare"
                                                  : "Punta la luce e tocca per bloccare")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(capture.cameraControlsLocked ? Theme.success : .white)
            }
        }
        .buttonStyle(.plain)
    }

    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(CaptureMode.allCases) { m in
                Button { if !bursting && !reviewingColumn && !autoRunning { mode = m } } label: {
                    Text(m.rawValue)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(mode == m ? Theme.navy : .white)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(mode == m ? Theme.yellow : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.black.opacity(0.5))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
        .opacity(bursting || reviewingColumn ? 0.4 : 1)
    }

    private var hint: some View {
        GlassPill {
            Image(systemName: mode == .auto ? "figure.walk" : (mode == .colonna ? "rectangle.stack" : "camera"))
                .foregroundStyle(Theme.yellow)
            Text(hintText)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private var hintText: String {
        switch mode {
        case .auto:
            return autoRunning ? "In cattura — muoviti lungo la facciata"
                               : "Tocca Start e cammina: scatta da solo"
        case .colonna: return "Tieni premuto lo scatto = raffica colonna"
        case .libera:  return "Tocca lo scatto = foto singola"
        }
    }

    /// Dati per la guida di copertura: proietta le posizioni world (XZ) dei frame
    /// catturati nella sessione corrente sull'asse principale del percorso
    /// (camminata laterale) → frazioni 0…1 dei coperti + posizione attuale.
    private var coverageData: (covered: [Double], current: Double?) {
        let frames = rilievo.frameCatturati.filter { $0.timestampMs >= capture.sessionStartedAtMs }
        let pts = frames.map { f -> SIMD2<Float> in
            let t = f.cameraTransformMatrix.columns.3
            return SIMD2<Float>(t.x, t.z)
        }
        var cur: SIMD2<Float>? = nil
        if let p = capture.currentPose { cur = SIMD2<Float>(p.columns.3.x, p.columns.3.z) }
        let all = pts + (cur.map { [$0] } ?? [])
        guard let origin = all.first, all.count >= 2 else {
            return ([], cur != nil ? 0.5 : nil)
        }
        // asse = direzione dal primo punto al più lontano (approssima la linea di camminata)
        let far = all.max(by: { simd_distance($0, origin) < simd_distance($1, origin) })!
        var axis = far - origin
        let len = simd_length(axis)
        guard len > 0.1 else { return ([], 0.5) }
        axis /= len
        func proj(_ p: SIMD2<Float>) -> Float { simd_dot(p - origin, axis) }
        let sCaptures = pts.map(proj)
        let sCur = cur.map(proj)
        let allS = sCaptures + (sCur.map { [$0] } ?? [])
        let lo = allS.min()!, hi = allS.max()!
        let span = max(hi - lo, 0.5), pad = max(hi - lo, 0.5) * 0.08
        func frac(_ s: Float) -> Double { Double((s - lo + pad) / (span + 2 * pad)) }
        return (sCaptures.map(frac), sCur.map(frac))
    }

    private var coverageGuide: some View {
        let data = coverageData
        return VStack(spacing: 5) {
            HStack {
                Image(systemName: "ruler").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Text("Copertura facciata").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("\(autoShotCount) scatti").font(Theme.Typo.mono(11, .semibold)).foregroundStyle(Theme.yellow)
            }
            CoverageStrip(covered: data.covered, current: data.current)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: 380)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    /// Progresso verso lo scatto automatico successivo (0…1): max tra spostamento
    /// e rotazione rispetto alle soglie. Riempie l'anello attorno allo scatto.
    private var autoProgress: Double {
        guard mode == .auto, autoRunning else { return 0 }
        let t = Double((capture.distanceFromLastCaptureM ?? 0) / autoMinTranslationM)
        let r = Double(capture.rotationFromLastCaptureDeg / autoMinRotationDeg)
        return min(max(t, r), 1)
    }

    /// Pannello esposizione: tempo di scatto (preset) + compensazione EV.
    private var cameraControlsPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "timer").foregroundStyle(Theme.yellow).font(.system(size: 13))
                ForEach(ShutterSpeed.allCases) { s in
                    Button { capture.shutterSpeed = s } label: {
                        Text(s.label)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(capture.shutterSpeed == s ? Theme.navy : .white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(capture.shutterSpeed == s ? Theme.yellow : Color.white.opacity(0.12),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.min").foregroundStyle(.white.opacity(0.7)).font(.system(size: 13))
                Slider(value: Binding(get: { Double(capture.exposureBiasEV) },
                                      set: { capture.exposureBiasEV = Float($0) }),
                       in: -2...2, step: 0.33)
                    .tint(Theme.yellow)
                Image(systemName: "sun.max.fill").foregroundStyle(Theme.yellow).font(.system(size: 13))
                Text(String(format: "%+.1f", capture.exposureBiasEV))
                    .font(Theme.Typo.mono(12, .semibold)).foregroundStyle(.white)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: 360)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

    /// Scatto: in Auto è Start/Stop (anello di progresso sul movimento),
    /// in Colonna è tieni-premuto (raffica), in Libera è tap (singola).
    private var shutterControl: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.5), lineWidth: 4).frame(width: 84, height: 84)
            if mode == .auto {
                Circle().trim(from: 0, to: autoProgress)
                    .stroke(Theme.yellow, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 84, height: 84)
                    .animation(.linear(duration: 0.2), value: autoProgress)
            }
            Circle()
                .fill(innerShutterColor)
                .frame(width: 68, height: 68)
                .shadow(color: innerShutterColor.opacity(0.45), radius: 12)
            if mode == .auto {
                Image(systemName: autoRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(autoRunning ? .white : Theme.navy)
            }
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onShutterDown() }
                .onEnded { _ in onShutterUp() }
        )
        .opacity(reviewingColumn ? 0.35 : 1)
        .allowsHitTesting(!reviewingColumn)
    }

    private var innerShutterColor: Color {
        if mode == .auto { return autoRunning ? Theme.danger : Theme.yellow }
        return bursting ? Theme.danger : Theme.yellow
    }

    /// Bottone ingranaggio per mostrare/nascondere il pannello esposizione.
    private var camControlsToggle: some View {
        Button { withAnimation { showCamControls.toggle() } } label: {
            GlassPill {
                Image(systemName: "slider.horizontal.3").foregroundStyle(showCamControls ? Theme.yellow : .white)
                Text(capture.shutterSpeed.label)
                    .font(Theme.Typo.mono(13, .semibold)).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private var undoButton: some View {
        CircleIconButton(systemImage: "arrow.uturn.backward",
                         background: AnyShapeStyle(.ultraThinMaterial)) {
            if !bursting { rilievo.rimuoviUltimoFrame() }
        }
    }

    private var fineButton: some View {
        PillButton(title: "Fine", systemImage: "checkmark.circle.fill",
                   foreground: Theme.navy, background: Theme.yellow) {
            completaLavoro()
        }
    }

    private var portraitChrome: some View {
        VStack {
            topBar
            if mode == .auto {
                coverageGuide.padding(.horizontal, 16).padding(.top, 8)
            }
            Spacer()
            VStack(spacing: 10) {
                if showCamControls { cameraControlsPanel }
                HStack(spacing: 10) { exposureBadge; camControlsToggle }
                modeSelector
                hint
            }
            Spacer().frame(height: 14)
            FrameStrip(thumbnails: rilievo.frameCatturati.compactMap { $0.thumbnailImage })
                .padding(.horizontal, 16).padding(.bottom, 10)
            HStack {
                undoButton
                Spacer()
                shutterControl
                Spacer()
                fineButton
            }
            .padding(.horizontal, 24).padding(.bottom, 34)
        }
    }

    private var landscapeChrome: some View {
        ZStack {
            HStack {
                GlassPillButton(systemImage: "xmark") { onAnnulla() }
                    .rotationEffect(landscapeToolRotation)
                Spacer()
                GlassPill {
                    Circle().fill(bursting ? Theme.danger : Theme.yellow).frame(width: 8, height: 8)
                    Text("\(elapsedString) · \(columnsSaved) col").font(Theme.Typo.mono(13, .semibold))
                }
                .rotationEffect(landscapeToolRotation)
            }
            .padding(.horizontal, 28).padding(.top, 24)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 10) {
                if showCamControls { cameraControlsPanel }
                HStack(spacing: 10) { exposureBadge; camControlsToggle }
                modeSelector
                hint
            }
            .rotationEffect(landscapeToolRotation)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(x: deviceOrientation == .landscapeLeft ? -60 : 60, y: 0)

            VStack(spacing: 18) {
                undoButton.rotationEffect(landscapeToolRotation)
                shutterControl
                fineButton.rotationEffect(landscapeToolRotation)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 34).padding(.bottom, 34)
        }
    }

    // MARK: Upload list (slide per foto)

    /// Pannello di caricamento: lista orizzontale (uno "slide" per foto) con
    /// stato per-foto (in coda / in corso / ✓ / ✗). Tap su ✗ = riprova.
    @ViewBuilder
    private var uploadListPanel: some View {
        if uploader.total > 0 {
            let finished = uploader.allFinished
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: finished ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                        .foregroundStyle(finished ? Theme.success : Theme.yellow)
                    Text(finished ? "Caricamento completato" : "Caricamento \(uploader.done)/\(uploader.total)")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    if uploader.failed > 0 {
                        Text("· \(uploader.failed) falliti")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                    }
                    Spacer()
                }
                ProgressView(value: Double(uploader.done), total: Double(max(uploader.total, 1)))
                    .tint(finished ? Theme.success : Theme.yellow)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(uploadingFrames, id: \.orderIndex) { uploadCard($0) }
                    }.padding(.horizontal, 2)
                }
                if uploader.failed > 0 {
                    Text("Tocca una foto rossa per riprovare").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(14)
            .frame(maxWidth: 460)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.18), lineWidth: 1))
            .padding(.horizontal, 16)
            .rotationEffect(isLandscapeDevice ? landscapeToolRotation : .zero)
        }
    }

    private func uploadCard(_ f: CapturedFacadePhoto) -> some View {
        let status = uploader.statusByOrder[f.orderIndex] ?? .pending
        return ZStack(alignment: .bottomTrailing) {
            if let d = f.thumbnailImage, let ui = UIImage(data: d) {
                Image(uiImage: ui).resizable().scaledToFill().frame(width: 60, height: 80).clipped()
            } else {
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 60, height: 80)
            }
            uploadStatusBadge(status).padding(4)
        }
        .frame(width: 60, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(uploadBorderColor(status), lineWidth: 2))
        .opacity(status == .pending ? 0.55 : 1)
        .onTapGesture { if status == .failed { uploader.retry(orderIndex: f.orderIndex) } }
    }

    @ViewBuilder
    private func uploadStatusBadge(_ s: UploadStatus) -> some View {
        switch s {
        case .pending:
            Image(systemName: "clock.fill").font(.system(size: 13))
                .foregroundStyle(.white).padding(3).background(Circle().fill(.black.opacity(0.6)))
        case .uploading:
            ProgressView().scaleEffect(0.7).tint(.white)
                .padding(3).background(Circle().fill(.black.opacity(0.6)))
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                .foregroundStyle(Theme.success).background(Circle().fill(.white))
        case .failed:
            Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 15))
                .foregroundStyle(.white).padding(3).background(Circle().fill(Theme.danger))
        }
    }

    private func uploadBorderColor(_ s: UploadStatus) -> Color {
        switch s {
        case .done: return Theme.success
        case .failed: return Theme.danger
        case .uploading: return Theme.yellow
        case .pending: return Color.white.opacity(0.25)
        }
    }

    /// Schermata di caricamento (dopo "Fine"): camera spenta, lista a griglia
    /// con stato per-foto, progresso, e uscita (l'upload prosegue in background).
    private var finishingView: some View {
        let finished = uploader.allFinished
        return ZStack {
            Color.black.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer().frame(height: 16)
                Image(systemName: finished ? "checkmark.circle.fill" : "icloud.and.arrow.up")
                    .font(.system(size: 38)).foregroundStyle(finished ? Theme.success : Theme.yellow)
                Text(finished ? "Caricamento completato" : "Caricamento foto…")
                    .font(.system(size: 22, weight: .black)).foregroundStyle(.white)
                Text(uploader.failed > 0
                     ? "\(uploader.done)/\(uploader.total) · \(uploader.failed) da riprovare"
                     : "\(uploader.done)/\(uploader.total)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.yellow)
                ProgressView(value: Double(uploader.done), total: Double(max(uploader.total, 1)))
                    .tint(finished ? Theme.success : Theme.yellow)
                    .padding(.horizontal, 30)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 8)], spacing: 8) {
                        ForEach(uploadingFrames, id: \.orderIndex) { uploadCard($0) }
                    }.padding(.horizontal, 20).padding(.top, 4)
                }
                if uploader.failed > 0 {
                    Text("Tocca le foto rosse per riprovare").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                Text("Puoi uscire: il caricamento prosegue in background, anche in standby.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
                PillButton(title: finished ? "Fatto" : "Esci (continua in background)",
                           systemImage: finished ? "checkmark" : "arrow.right",
                           foreground: Theme.navy, background: Theme.yellow) { chiudiLavoro() }
                    .padding(.bottom, 28)
            }
        }
        .transition(.opacity)
    }

    /// Pannello Salva / Rifai dopo il rilascio della raffica.
    private var reviewPanel: some View {
        VStack(spacing: 16) {
            Text("Colonna acquisita")
                .font(.system(size: 20, weight: .black)).foregroundStyle(.white)
            Text("\(columnFrameCount) foto in raffica")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.yellow)
            HStack(spacing: 14) {
                PillButton(title: "Rifai", systemImage: "arrow.counterclockwise",
                           foreground: .white, background: Theme.danger) { redoColumn() }
                PillButton(title: "Salva colonna", systemImage: "checkmark",
                           foreground: Theme.navy, background: Theme.yellow) { saveColumn() }
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 22)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .rotationEffect(isLandscapeDevice ? landscapeToolRotation : .zero)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Exposure

    @MainActor
    private func toggleExposureLock() {
        if capture.cameraControlsLocked {
            capture.unlockCameraControls()
        } else {
            capture.lockCameraControlsForFacadeCapture()
        }
        let g = UIImpactFeedbackGenerator(style: .rigid); g.prepare(); g.impactOccurred()
    }

    // MARK: Shutter interaction

    @MainActor
    private func onShutterDown() {
        guard !reviewingColumn else { return }
        switch mode {
        case .auto:
            if !shotThisPress {
                shotThisPress = true
                if autoRunning { stopAuto() } else { startAuto() }
                let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); g.impactOccurred()
            }
        case .colonna:
            if !bursting { startColumn() }
        case .libera:
            if !shotThisPress {
                shotThisPress = true
                Task {
                    if await scatta(upload: true) { triggerFlash() }
                }
            }
        }
    }

    @MainActor
    private func onShutterUp() {
        switch mode {
        case .auto:    shotThisPress = false
        case .colonna: endColumn()
        case .libera:  shotThisPress = false
        }
    }

    // MARK: Auto capture (stile RealityScan)

    /// Scatta automaticamente quando ci si è spostati ≥ soglia traslazione OPPURE
    /// ruotati ≥ soglia angolare dall'ultima cattura → overlap costante senza
    /// foto ridondanti. Il primo scatto parte appena premi Start.
    @MainActor
    private func startAuto() {
        autoStartIndex = rilievo.frameCatturati.count
        autoNeedsFirstShot = true
        autoRunning = true
    }

    @MainActor
    private func stopAuto() {
        autoRunning = false
        // Carica ORA il batch acquisito (durante la cattura NON si carica → niente
        // timeout a catena). Coda affidabile con retry.
        let frames = Array(rilievo.frameCatturati.suffix(from: min(autoStartIndex, rilievo.frameCatturati.count)))
        Task { await enqueueUpload(frames) }
    }

    /// Cattura automatica: scatta su movimento/rotazione, **senza** caricare
    /// (upload differito allo Stop). I frame restano su disco.
    @MainActor
    private func autoTick() async {
        guard mode == .auto, autoRunning, !capture.isBusy else { return }
        guard capture.trackingState == "normal" else { return }
        let moved = (capture.distanceFromLastCaptureM ?? 0) >= autoMinTranslationM
        let rotated = capture.rotationFromLastCaptureDeg >= autoMinRotationDeg
        guard autoNeedsFirstShot || moved || rotated else { return }
        if await scatta(upload: false) {
            autoNeedsFirstShot = false
            autoShotCount += 1
            triggerFlash()
            let g = UIImpactFeedbackGenerator(style: .light); g.prepare(); g.impactOccurred()
        }
    }

    // MARK: Column lifecycle

    @MainActor
    private func startColumn() {
        columnStartIndex = rilievo.frameCatturati.count
        columnFrameCount = 0
        lastBurstAt = .distantPast
        bursting = true
        let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); g.impactOccurred()
    }

    @MainActor
    private func endColumn() {
        guard bursting else { return }
        bursting = false
        if columnFrameCount > 0 {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { reviewingColumn = true }
        }
    }

    @MainActor
    private func saveColumn() {
        // Upload dei frame della colonna solo ora (durante la raffica non si carica).
        let frames = Array(rilievo.frameCatturati.suffix(from: min(columnStartIndex, rilievo.frameCatturati.count)))
        Task { await enqueueUpload(frames) }
        columnsSaved += 1
        columnFrameCount = 0
        withAnimation { reviewingColumn = false }
        let g = UINotificationFeedbackGenerator(); g.prepare(); g.notificationOccurred(.success)
    }

    @MainActor
    private func redoColumn() {
        // Scarta i frame della colonna (non ancora caricati).
        while rilievo.frameCatturati.count > columnStartIndex { rilievo.rimuoviUltimoFrame() }
        columnFrameCount = 0
        withAnimation { reviewingColumn = false }
        let g = UINotificationFeedbackGenerator(); g.prepare(); g.notificationOccurred(.warning)
    }

    @MainActor
    private func completaLavoro() {
        guard !reviewingColumn else { return }
        autoRunning = false
        capture.pauseSession()        // SPEGNE la fotocamera → niente più calore
        finishing = true              // mostra la schermata di caricamento
        // Accoda TUTTO ciò che non è già caricato/in coda. Da qui l'upload va in
        // background: prosegue anche in standby e riprende dopo un crash.
        let pending = rilievo.frameCatturati.filter { uploader.statusByOrder[$0.orderIndex] != .done }
        Task {
            await enqueueUpload(pending)
            if let sid = backendSessionId {
                uploader.finishCapture(sessionId: sid)
            }
        }
    }

    /// Esce dalla schermata di caricamento. Gli upload non ancora finiti
    /// proseguono comunque in background.
    @MainActor
    private func chiudiLavoro() {
        rilievo.sessionId = backendSessionId
        rilievo.stato = .elaborato
        onCompletato()
    }

    // MARK: Burst tick

    @MainActor
    private func burstTick() async {
        guard bursting, mode == .colonna, !capture.isBusy else { return }
        guard capture.trackingState == "normal" else { return }
        guard Date().timeIntervalSince(lastBurstAt) >= burstIntervalSec else { return }
        lastBurstAt = Date()
        if await scatta(upload: false) {
            columnFrameCount += 1
            triggerFlash()
            let g = UIImpactFeedbackGenerator(style: .light); g.prepare(); g.impactOccurred()
        }
    }

    @MainActor
    private func triggerFlash() {
        withAnimation(.easeOut(duration: 0.06)) { burstFlash = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeOut(duration: 0.18)) { burstFlash = false }
        }
    }

    // MARK: Capture / upload

    @MainActor
    private func scatta(upload: Bool) async -> Bool {
        do {
            let idx = rilievo.frameCatturati.count
            let photo = try await capture.captureHighResolutionPhoto(orderIndex: idx)
            rilievo.aggiungiFrame(photo)
            if upload { Task { await enqueueUpload([photo]) } }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Accoda i frame all'uploader di BACKGROUND (sopravvive a standby/crash).
    /// Crea la sessione una sola volta, poi delega tutto al BackgroundUploader.
    /// Esclude i frame già completati o già in coda.
    private func enqueueUpload(_ frames: [CapturedFacadePhoto]) async {
        let toSend = frames.filter { uploader.statusByOrder[$0.orderIndex] != .done }
        guard !toSend.isEmpty else { return }
        do {
            let sid = try await BackendAPIClient.shared.ensureSession()
            await MainActor.run {
                backendSessionId = sid
                uploader.enqueue(sessionId: sid, photos: toSend)
            }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    /// Frame attualmente in coda/caricati (per la lista), ordinati.
    private var uploadingFrames: [CapturedFacadePhoto] {
        rilievo.frameCatturati
            .filter { uploader.statusByOrder[$0.orderIndex] != nil }
            .sorted { $0.orderIndex < $1.orderIndex }
    }
}

// MARK: - Coverage strip

/// Striscia di copertura della facciata: barra orizzontale dove i segmenti verdi
/// sono già coperti dagli scatti, i grigi sono buchi da coprire, e il cursore
/// giallo è la posizione attuale lungo la linea di camminata.
private struct CoverageStrip: View {
    let covered: [Double]       // frazioni 0…1 delle posizioni catturate
    let current: Double?        // frazione 0…1 posizione attuale
    private let segments = 30

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let segW = w / CGFloat(segments)
            ZStack(alignment: .topLeading) {
                ForEach(0..<segments, id: \.self) { i in
                    let lo = Double(i) / Double(segments)
                    let hi = Double(i + 1) / Double(segments)
                    let isCov = covered.contains { $0 >= lo && $0 < hi }
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isCov ? Theme.success.opacity(0.9) : Color.white.opacity(0.10))
                        .frame(width: max(segW - 2, 1), height: h)
                        .offset(x: CGFloat(i) * segW)
                }
                if let c = current {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.yellow)
                        .frame(width: 3, height: h + 6)
                        .offset(x: CGFloat(c) * w - 1.5, y: -3)
                        .shadow(color: Theme.yellow.opacity(0.85), radius: 4)
                }
            }
        }
        .frame(height: 20)
    }
}
