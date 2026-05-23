import SwiftUI

/// Rettifica facciata via 4-tap homography 2D sul panorama esistente.
/// Sostituisce il flusso 3D-triangolato (TapWallPlaneView) per il caso utente.
///
/// UX:
///  - Mostra il panorama scaricato da backend (stitched.jpg della sessione)
///  - L'utente tappa 4 punti del MURO PRINCIPALE in ordine TL → TR → BR → BL
///  - Drag per regolare i punti dopo averli piazzati
///  - "Calcola" invia al backend /rectify-panorama
///  - Al ritorno mostra la facciata rettificata + apre MeasureScaleView
struct RectifyFacadeView: View {
    let sessionId: String
    let panoramaURL: URL
    let onCompletato: (URL) -> Void   // URL del rectified_facade
    let onAnnulla: () -> Void

    @State private var panoramaImage: UIImage?
    @State private var loadError: String?
    @State private var taps: [CGPoint] = []          // pixel del panorama (NON dello schermo)
    @State private var dragIdx: Int?
    @State private var inviando = false
    @State private var serverErr: String?

    private let cornerNames = ["TL", "TR", "BR", "BL"]
    private let cornerColors: [Color] = [.yellow, .green, .orange, .pink]
    private let grabRadiusScreenPx: CGFloat = 22

    var body: some View {
        ZStack { Theme.paper.ignoresSafeArea(); content }
        .task { await loadPanorama() }
        .alert("Errore", isPresented: Binding(get: { serverErr != nil }, set: { if !$0 { serverErr = nil } })) {
            Button("OK") { serverErr = nil }
        } message: { Text(serverErr ?? "") }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 10) {
            header
            istruzioniBanner
            photoArea
            actionBar
        }
        .padding(.bottom, 14)
    }

    private var header: some View {
        HStack {
            Button("Annulla") { onAnnulla() }.foregroundColor(Theme.navy)
            Spacer()
            Text("Definisci facciata").font(Theme.Typo.title(17)).foregroundStyle(Theme.navy)
            Spacer()
            Text("\(taps.count)/4").font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var istruzioniBanner: some View {
        let text: String
        if taps.count == 0 { text = "Tappa l'angolo TL del muro principale (alto-sinistra)" }
        else if taps.count < 4 { text = "Adesso \(cornerNames[taps.count]) (\(["alto-sinistra","alto-destra","basso-destra","basso-sinistra"][taps.count]))" }
        else { text = "Trascina i punti per regolare la posizione, poi conferma." }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: taps.count == 4 ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(taps.count == 4 ? Theme.success : Theme.navy)
                Text(text).font(Theme.Typo.body(13))
                Spacer()
            }
            Text("Non tappare su porte rientrate, vetrine o pensiline. Scegli il MURO principale.")
                .font(Theme.Typo.caption(11)).foregroundStyle(Theme.danger)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.yellow.opacity(0.20), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var photoArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = panoramaImage {
                    let info = scaledInfo(img: img, frame: geo.size)
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: info.renderedW, height: info.renderedH)
                        .position(x: info.offsetX + info.renderedW/2,
                                  y: info.offsetY + info.renderedH/2)
                    // Polygon dei tap
                    if taps.count >= 2 {
                        Path { path in
                            let pts = taps.map { screenPoint(forPanoramaPixel: $0, info: info) }
                            path.move(to: pts[0])
                            for p in pts.dropFirst() { path.addLine(to: p) }
                            if taps.count == 4 { path.closeSubpath() }
                        }
                        .stroke(Theme.yellow.opacity(0.85), lineWidth: 1.5)
                    }
                    // Markers
                    ForEach(Array(taps.enumerated()), id: \.offset) { i, p in
                        let sp = screenPoint(forPanoramaPixel: p, info: info)
                        markerView(idx: i, isActive: i == dragIdx).position(sp)
                    }
                } else if let e = loadError {
                    VStack { Image(systemName: "exclamationmark.triangle").font(.largeTitle); Text(e) }
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in handleTouch(value.location, geo: geo, ended: false) }
                    .onEnded   { value in handleTouch(value.location, geo: geo, ended: true)  }
            )
        }
        .padding(.horizontal, 16)
    }

    private func markerView(idx: Int, isActive: Bool) -> some View {
        let r: CGFloat = isActive ? 18 : 14
        return ZStack {
            Circle().stroke(.white, lineWidth: 2).frame(width: r*2, height: r*2)
            Circle().fill(cornerColors[idx]).frame(width: 8, height: 8)
            Text(cornerNames[idx])
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(.white)
                .padding(.leading, r*2 + 4)
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            BrandButton(title: "Rimuovi ultimo tap",
                        systemImage: "arrow.uturn.backward", kind: .ghost) {
                if !taps.isEmpty { taps.removeLast() }
            }
            .disabled(taps.isEmpty).opacity(taps.isEmpty ? 0.4 : 1)

            BrandButton(title: inviando ? "Calcolo…" :
                            (taps.count == 4 ? "Calcola rettifica" : "Servono 4 punti"),
                        systemImage: taps.count == 4 ? "checkmark.circle.fill" : "info.circle",
                        kind: .primary) {
                Task { await invia() }
            }
            .disabled(taps.count != 4 || inviando)
            .opacity(taps.count == 4 ? 1 : 0.6)
        }
        .padding(.horizontal, 16)
    }

    // MARK: – Touch handling con drag su markers esistenti

    private func handleTouch(_ pt: CGPoint, geo: GeometryProxy, ended: Bool) {
        guard let img = panoramaImage else { return }
        let info = scaledInfo(img: img, frame: geo.size)

        // Se stiamo già trascinando un marker → aggiornalo
        if let i = dragIdx {
            taps[i] = panoramaPixel(forScreenPoint: pt, info: info, img: img)
            if ended { dragIdx = nil }
            return
        }

        // Inizio touch: vedo se è vicino a un marker esistente
        let nearestIdx = taps.enumerated().min { (a, b) in
            distance2(screenPoint(forPanoramaPixel: a.element, info: info), pt) <
            distance2(screenPoint(forPanoramaPixel: b.element, info: info), pt)
        }
        if let nearest = nearestIdx,
           distance2(screenPoint(forPanoramaPixel: nearest.element, info: info), pt) <=
           (grabRadiusScreenPx * grabRadiusScreenPx) {
            dragIdx = nearest.offset
            return
        }
        // Altrimenti: piazza un nuovo tap (solo se ne mancano)
        if taps.count < 4 {
            taps.append(panoramaPixel(forScreenPoint: pt, info: info, img: img))
        }
    }

    // MARK: – Math di conversione screen ↔ pixel del panorama

    private struct ScaleInfo { let renderedW, renderedH, offsetX, offsetY, scale: CGFloat }

    private func scaledInfo(img: UIImage, frame: CGSize) -> ScaleInfo {
        let pxW = img.size.width, pxH = img.size.height
        let s = min(frame.width / pxW, frame.height / pxH)
        let rW = pxW * s, rH = pxH * s
        return ScaleInfo(
            renderedW: rW, renderedH: rH,
            offsetX: (frame.width - rW)/2, offsetY: (frame.height - rH)/2,
            scale: s
        )
    }

    private func screenPoint(forPanoramaPixel p: CGPoint, info: ScaleInfo) -> CGPoint {
        CGPoint(x: info.offsetX + p.x * info.scale,
                y: info.offsetY + p.y * info.scale)
    }
    private func panoramaPixel(forScreenPoint p: CGPoint, info: ScaleInfo, img: UIImage) -> CGPoint {
        let x = max(0, min(img.size.width  - 1, (p.x - info.offsetX) / info.scale))
        let y = max(0, min(img.size.height - 1, (p.y - info.offsetY) / info.scale))
        return CGPoint(x: x, y: y)
    }
    private func distance2(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx*dx + dy*dy
    }

    // MARK: – Backend

    private func loadPanorama() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: panoramaURL)
            if let img = UIImage(data: data) {
                await MainActor.run { self.panoramaImage = img }
            } else {
                await MainActor.run { self.loadError = "Decode panorama fallito" }
            }
        } catch {
            await MainActor.run { self.loadError = error.localizedDescription }
        }
    }

    private func invia() async {
        guard taps.count == 4 else { return }
        inviando = true; defer { inviando = false }
        do {
            let quad = taps.map { (Double($0.x), Double($0.y)) }
            let res = try await BackendAPIClient.shared.rectifyPanorama(
                sessionId: sessionId, srcQuad: quad, source: "stitched")
            guard let url = URL(string: res.rectified_url) else {
                throw NSError(domain: "Acro", code: 1, userInfo: [NSLocalizedDescriptionKey: "URL invalido"])
            }
            await MainActor.run { onCompletato(url) }
        } catch {
            await MainActor.run { serverErr = error.localizedDescription }
        }
    }
}
