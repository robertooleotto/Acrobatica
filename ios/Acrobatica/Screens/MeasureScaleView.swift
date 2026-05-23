import SwiftUI

/// Imposta la scala metrica della facciata rettificata via 2 tap + distanza nota.
/// Da chiamare dopo RectifyFacadeView.
///
/// UX:
///  - Mostra il rectified_facade.jpg
///  - Utente tappa 2 punti (con drag fine come in RectifyFacadeView)
///  - Inserisce la distanza reale fra i 2 punti (m), es. "altezza porta = 2.10"
///  - Backend calcola e salva meters_per_pixel
struct MeasureScaleView: View {
    let sessionId: String
    let rectifiedURL: URL
    let onCompletato: (Double) -> Void   // meters_per_pixel
    let onAnnulla: () -> Void

    @State private var img: UIImage?
    @State private var loadError: String?
    @State private var taps: [CGPoint] = []          // pixel del rectified
    @State private var dragIdx: Int?
    @State private var distanzaStr: String = ""
    @State private var inviando = false
    @State private var serverErr: String?

    var body: some View {
        ZStack { Theme.paper.ignoresSafeArea(); content }
            .task { await loadImage() }
            .alert("Errore", isPresented: Binding(get: { serverErr != nil }, set: { if !$0 { serverErr = nil } })) {
                Button("OK") { serverErr = nil }
            } message: { Text(serverErr ?? "") }
    }

    private var content: some View {
        VStack(spacing: 10) {
            header
            banner
            photoArea
            distanzaField
            BrandButton(
                title: inviando ? "Calcolo…" :
                    (taps.count == 2 && parsedDistance != nil ? "Imposta scala" : "Servono 2 tap + distanza"),
                systemImage: "checkmark.circle.fill", kind: .primary
            ) { Task { await invia() } }
            .disabled(taps.count != 2 || parsedDistance == nil || inviando)
            .opacity(taps.count == 2 && parsedDistance != nil ? 1 : 0.6)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 14)
    }

    private var header: some View {
        HStack {
            Button("Annulla") { onAnnulla() }.foregroundColor(Theme.navy)
            Spacer()
            Text("Imposta scala").font(Theme.Typo.title(17)).foregroundStyle(Theme.navy)
            Spacer()
            Text("\(taps.count)/2").font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var banner: some View {
        let text = taps.count == 0 ? "Tappa il primo punto (es. base di una porta)" :
                   taps.count == 1 ? "Tappa il secondo punto a distanza nota (es. cima della stessa porta)" :
                   "Inserisci la distanza reale fra i 2 punti, in metri."
        return HStack(spacing: 8) {
            Image(systemName: taps.count == 2 ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(taps.count == 2 ? Theme.success : Theme.navy)
            Text(text).font(Theme.Typo.body(13))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.yellow.opacity(0.20), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }

    private var photoArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let im = img {
                    let info = ScaleHelper.fit(img: im, frame: geo.size)
                    Image(uiImage: im)
                        .resizable().frame(width: info.renderedW, height: info.renderedH)
                        .position(x: info.offsetX + info.renderedW/2,
                                  y: info.offsetY + info.renderedH/2)
                    if taps.count == 2 {
                        Path { p in
                            let p1 = ScaleHelper.screenPoint(taps[0], info: info)
                            let p2 = ScaleHelper.screenPoint(taps[1], info: info)
                            p.move(to: p1); p.addLine(to: p2)
                        }
                        .stroke(Theme.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                    ForEach(Array(taps.enumerated()), id: \.offset) { i, p in
                        let sp = ScaleHelper.screenPoint(p, info: info)
                        ZStack {
                            Circle().stroke(.white, lineWidth: 2).frame(width: 28, height: 28)
                            Circle().fill(Theme.yellow).frame(width: 10, height: 10)
                            Text("\(i+1)").font(.system(size: 12, weight: .heavy))
                                .foregroundColor(Theme.navy)
                                .padding(.leading, 30)
                        }
                        .position(sp).shadow(color: .black.opacity(0.5), radius: 3)
                    }
                } else if let e = loadError {
                    Text(e).foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in handle(v.location, geo: geo, ended: false) }
                    .onEnded   { v in handle(v.location, geo: geo, ended: true)  }
            )
        }
        .padding(.horizontal, 16)
    }

    private var distanzaField: some View {
        HStack(spacing: 8) {
            Text("Distanza nota:").font(Theme.Typo.body(14))
            TextField("es. 2.10", text: $distanzaStr)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .frame(maxWidth: 120)
            Text("m").font(Theme.Typo.body(14)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var parsedDistance: Double? {
        let s = distanzaStr.replacingOccurrences(of: ",", with: ".")
        return Double(s).flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: – Touch

    private func handle(_ pt: CGPoint, geo: GeometryProxy, ended: Bool) {
        guard let im = img else { return }
        let info = ScaleHelper.fit(img: im, frame: geo.size)
        if let i = dragIdx {
            taps[i] = ScaleHelper.panoramaPixel(pt, info: info, img: im)
            if ended { dragIdx = nil }
            return
        }
        // Cerca marker vicino per grab
        let pts = taps.map { ScaleHelper.screenPoint($0, info: info) }
        if let nearest = pts.enumerated().min(by: { hypot($0.element.x - pt.x, $0.element.y - pt.y) <
                                                    hypot($1.element.x - pt.x, $1.element.y - pt.y) }),
           hypot(nearest.element.x - pt.x, nearest.element.y - pt.y) <= 24 {
            dragIdx = nearest.offset; return
        }
        if taps.count < 2 {
            taps.append(ScaleHelper.panoramaPixel(pt, info: info, img: im))
        }
    }

    private func loadImage() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: rectifiedURL)
            if let i = UIImage(data: data) { await MainActor.run { img = i } }
            else { await MainActor.run { loadError = "decode fallito" } }
        } catch { await MainActor.run { loadError = error.localizedDescription } }
    }

    private func invia() async {
        guard taps.count == 2, let d = parsedDistance else { return }
        inviando = true; defer { inviando = false }
        do {
            let res = try await BackendAPIClient.shared.setScale(
                sessionId: sessionId,
                p1: (Double(taps[0].x), Double(taps[0].y)),
                p2: (Double(taps[1].x), Double(taps[1].y)),
                distanceM: d
            )
            await MainActor.run { onCompletato(res.meters_per_pixel) }
        } catch {
            await MainActor.run { serverErr = error.localizedDescription }
        }
    }
}

// Helper condiviso: math di scaling immagine → frame
enum ScaleHelper {
    struct Info { let renderedW, renderedH, offsetX, offsetY, scale: CGFloat }
    static func fit(img: UIImage, frame: CGSize) -> Info {
        let pxW = img.size.width, pxH = img.size.height
        let s = min(frame.width / pxW, frame.height / pxH)
        let rW = pxW * s, rH = pxH * s
        return Info(renderedW: rW, renderedH: rH,
                    offsetX: (frame.width - rW)/2, offsetY: (frame.height - rH)/2, scale: s)
    }
    static func screenPoint(_ p: CGPoint, info: Info) -> CGPoint {
        CGPoint(x: info.offsetX + p.x * info.scale, y: info.offsetY + p.y * info.scale)
    }
    static func panoramaPixel(_ p: CGPoint, info: Info, img: UIImage) -> CGPoint {
        let x = max(0, min(img.size.width  - 1, (p.x - info.offsetX) / info.scale))
        let y = max(0, min(img.size.height - 1, (p.y - info.offsetY) / info.scale))
        return CGPoint(x: x, y: y)
    }
}
