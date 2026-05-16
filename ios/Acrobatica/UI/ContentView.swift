import SwiftUI

struct ContentView: View {
    @StateObject private var capture = ARFacadeCaptureManager()
    @State private var session = FacadeCaptureSession()
    @State private var error: String?
    @State private var uploadingCount: Int = 0
    @State private var processing: Bool = false
    @State private var lastResult: BackendAPIClient.ProcessResult?

    var body: some View {
        ZStack {
            ARPreviewView(manager: capture)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                if let r = lastResult { resultCard(r) }
                bottomBar
            }
            .padding()
        }
        .alert("Errore", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Acrobatica Facciate").font(.title2).bold()
            HStack(spacing: 8) {
                chip(label: capture.trackingState == "normal" ? "Tracking OK" : capture.trackingState,
                     color: capture.trackingState == "normal" ? .green : .yellow)
                chip(label: capture.hasLidar ? "LiDAR" : "no LiDAR",
                     color: capture.hasLidar ? .blue : .gray)
                if uploadingCount > 0 {
                    chip(label: "Upload \(uploadingCount)…", color: .orange)
                }
                if processing {
                    chip(label: "Processing…", color: .orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if !session.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.photos) { p in
                            ZStack(alignment: .topLeading) {
                                if let data = p.thumbnailImage, let img = UIImage(data: data) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipped()
                                        .cornerRadius(8)
                                }
                                Text("\(p.orderIndex + 1)")
                                    .font(.caption2).bold().foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.black.opacity(0.7), in: Capsule())
                                    .padding(3)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                actionButton(title: "Azzera", systemImage: "trash", color: .gray, enabled: !session.photos.isEmpty) {
                    session = FacadeCaptureSession()
                    lastResult = nil
                }
                Spacer()
                Button(action: shoot) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 60, height: 60)
                    }
                }
                .disabled(capture.isBusy)
                .opacity(capture.isBusy ? 0.5 : 1)
                Spacer()
                actionButton(title: "Misura", systemImage: "arrow.up.right.square", color: .green, enabled: session.photos.count >= 2 && !processing) {
                    Task { await processSession() }
                }
            }
            Text(hintText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private var hintText: String {
        if session.photos.isEmpty { return "Inquadra la facciata e premi lo scatto. Sposta il telefono lateralmente di 1-3 m tra una foto e l'altra." }
        if session.photos.count == 1 { return "Spostati e scatta almeno un altro frame da angolo diverso." }
        return "Pronto: premi Misura per inviare al backend."
    }

    private func resultCard(_ r: BackendAPIClient.ProcessResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Risultato backend").font(.headline)
            if let m2 = r.net_area_m2 {
                Text(String(format: "Netto: %.2f m²", m2)).font(.title3).bold().foregroundStyle(.green)
            } else {
                Text(String(format: "Netto: %.0f px²", r.net_area_pixels)).foregroundStyle(.green)
                Text("(scala metrica non fornita)").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            if let s = r.stitched_url {
                Text("stitched: \(s)").font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            if !r.warnings.isEmpty {
                ForEach(r.warnings, id: \.self) { w in
                    Text("⚠️ \(w)").font(.caption).foregroundStyle(.yellow)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private func chip(label: String, color: Color) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(color, lineWidth: 1))
    }

    private func actionButton(title: String, systemImage: String, color: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(enabled ? color : .gray)
            .frame(width: 60, height: 60)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!enabled)
    }

    // MARK: - Actions

    private func shoot() {
        let idx = session.photos.count
        Task {
            do {
                let photo = try await capture.captureHighResolutionPhoto(orderIndex: idx)
                session.photos.append(photo)
                // Upload async non bloccante.
                Task { await uploadAsync(photo) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func uploadAsync(_ photo: CapturedFacadePhoto) async {
        uploadingCount += 1
        defer { uploadingCount -= 1 }
        do {
            if session.backendSessionId == nil {
                let sid = try await BackendAPIClient.shared.createSession()
                session.backendSessionId = sid
            }
            guard let sid = session.backendSessionId else { return }
            _ = try await BackendAPIClient.shared.uploadPhoto(sessionId: sid, photo: photo)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func processSession() async {
        guard let sid = session.backendSessionId else {
            error = "Sessione backend non creata: ricarica e riscatta."
            return
        }
        processing = true
        defer { processing = false }
        do {
            lastResult = try await BackendAPIClient.shared.processSession(sessionId: sid)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
}
