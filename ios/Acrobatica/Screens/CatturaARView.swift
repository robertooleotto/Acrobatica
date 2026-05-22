import SwiftUI

/// Schermata AR live: wraps `ARFacadeCaptureManager`, mostra reticle, ghost
/// dell'ultimo scatto, film strip e bottoni.
///
/// Bridge:
///  - `rilievo.aggiungiFrame(_)`  ← `capture.captureHighResolutionPhoto(...)`
///  - upload + creazione `backendSessionId` ← `BackendAPIClient.shared`
struct CatturaARView: View {
    @ObservedObject var rilievo: Rilievo
    let onCompletato: () -> Void
    let onAnnulla: () -> Void

    @StateObject private var capture = ARFacadeCaptureManager()
    @State private var backendSessionId: String?
    @State private var uploadingCount: Int = 0
    @State private var startedAt: Date = .now
    @State private var elapsedTick: Int = 0
    @State private var errorMessage: String?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 1) Live AR + panorama strip nello STESSO frame 3:4 così i bordi combaciano.
            ZStack {
                ARPreviewView(manager: capture)
                PanoramaStripOverlay(lastThumbnail: rilievo.frameCatturati.last?.thumbnailImage)
                    .animation(.easeOut(duration: 0.35), value: rilievo.frameCatturati.count)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .ignoresSafeArea()

            // 3) Reticle neutro (niente aggancio piano: ARKit non lo fa affidabile a distanza)
            ReticleOverlay()
                .padding(.horizontal, 56)
                .padding(.vertical, 220)

            // 4) Chrome
            VStack {
                topBar
                Spacer()
                hint
                Spacer().frame(height: 12)
                FrameStrip(thumbnails: rilievo.frameCatturati.compactMap { $0.thumbnailImage })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onReceive(timer) { _ in elapsedTick += 1 }
        .alert("Errore", isPresented: Binding(get: { errorMessage != nil },
                                              set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: – Chrome

    private var topBar: some View {
        HStack {
            GlassPillButton(systemImage: "xmark") { onAnnulla() }
            Spacer()
            GlassPill {
                Circle().fill(Theme.yellow).frame(width: 8, height: 8)
                    .shadow(color: Theme.yellow.opacity(0.45), radius: 4)
                Text("REC · \(elapsedString)")
                    .font(Theme.Typo.mono(13, .semibold))
            }
            Spacer()
            GlassPillButton(systemImage: uploadingCount > 0 ? "icloud.and.arrow.up" : "bolt.slash.fill") {
                // toggle flash (placeholder) — non implementato sul manager.
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var hint: some View {
        VStack(spacing: 8) {
            // Baseline / spostamento dall'ultimo scatto.
            // Per un piano del muro triangolabile servono ≥ 60-80 cm tra scatti.
            if !rilievo.frameCatturati.isEmpty, let d = capture.distanceFromLastCaptureM {
                baselineChip(meters: d)
            }
            if let testo = hintText {
                GlassPill {
                    Image(systemName: hintIcon).foregroundStyle(Theme.yellow)
                    Text(testo).font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }

    /// Chip "spostamento dall'ultimo scatto". Verde se ≥ 0.6 m, giallo 0.3-0.6 m, rosso < 0.3 m.
    /// Aiuta l'operatore a tenere baseline sufficiente per la triangolazione 3D del muro.
    private func baselineChip(meters d: Float) -> some View {
        let color: Color
        let icon: String
        let text: String
        switch d {
        case ..<0.3:
            color = Theme.danger
            icon = "exclamationmark.triangle.fill"
            text = "Spostati: \(String(format: "%.2f", d)) m"
        case 0.3..<0.6:
            color = Theme.warning
            icon = "arrow.left.and.right"
            text = "Quasi: \(String(format: "%.2f", d)) m"
        default:
            color = Theme.success
            icon = "checkmark.circle.fill"
            text = "Baseline OK: \(String(format: "%.2f", d)) m"
        }
        return GlassPill {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 14, weight: .semibold))
        }
    }

    private var bottomBar: some View {
        HStack {
            CircleIconButton(systemImage: "arrow.uturn.backward",
                             background: AnyShapeStyle(.ultraThinMaterial)) {
                rilievo.rimuoviUltimoFrame()
            }
            Spacer()
            ShutterButton { Task { await scatta() } }
            Spacer()
            PillButton(title: "Stop", systemImage: "stop.fill",
                       foreground: Theme.yellow, background: Theme.navy) {
                rilievo.sessionId = backendSessionId
                rilievo.stato = .elaborato
                onCompletato()
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 36)
    }

    // MARK: – Hint logic

    private var hintIcon: String { "viewfinder" }

    private var hintText: String? {
        if rilievo.frameCatturati.isEmpty {
            return "Inquadra la facciata e scatta"
        }
        if rilievo.frameCatturati.count == 1 {
            return "Spostati ~1m a lato, mantieni l'overlap con la striscia, poi scatta"
        }
        if rilievo.frameCatturati.count < 5 {
            return "Continua a panare lateralmente"
        }
        return nil
    }

    private var elapsedString: String {
        let s = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: – Capture / upload

    @MainActor
    private func scatta() async {
        do {
            let idx = rilievo.frameCatturati.count
            let photo = try await capture.captureHighResolutionPhoto(orderIndex: idx)
            rilievo.aggiungiFrame(photo)
            Task { await uploadAsync(photo) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func uploadAsync(_ photo: CapturedFacadePhoto) async {
        await MainActor.run { uploadingCount += 1 }
        defer { Task { @MainActor in uploadingCount -= 1 } }
        do {
            if backendSessionId == nil {
                let sid = try await BackendAPIClient.shared.createSession()
                await MainActor.run { backendSessionId = sid }
            }
            guard let sid = backendSessionId else { return }
            _ = try await BackendAPIClient.shared.uploadPhoto(sessionId: sid, photo: photo)
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }
}
