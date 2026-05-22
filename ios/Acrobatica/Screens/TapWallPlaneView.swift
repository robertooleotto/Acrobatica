import SwiftUI
import UIKit

/// Vista per tappare i 4 angoli del muro su 2+ foto della sessione → backend
/// triangola → fit del piano → ortorettifica e mostra il composito.
///
/// UX:
///  - Picker dell'angolo corrente (TL / TR / BR / BL) in alto
///  - Foto corrente al centro con eventuali marker già piazzati
///  - Strip di thumbnail in basso per cambiare foto
///  - Quando ogni angolo ha ≥ 2 tap su foto diverse, "Calcola" attivo
struct TapWallPlaneView: View {
    @ObservedObject var rilievo: Rilievo
    let sessionId: String
    let onCompletato: (URL?) -> Void   // callback con composite_url
    let onAnnulla: () -> Void

    enum Corner: String, CaseIterable, Identifiable {
        case TL, TR, BR, BL
        var id: String { rawValue }
        var nome: String {
            switch self {
            case .TL: return "Alto · Sinistra"
            case .TR: return "Alto · Destra"
            case .BR: return "Basso · Destra"
            case .BL: return "Basso · Sinistra"
            }
        }
        var indice: Int {
            switch self {
            case .TL: return 0
            case .TR: return 1
            case .BR: return 2
            case .BL: return 3
            }
        }
    }

    /// Un tap: (foto, pixel in coordinate ARKit landscape native)
    struct Tap: Identifiable, Hashable {
        let id = UUID()
        let photoIdx: Int
        let pxLandscape: CGPoint   // pixel nel frame ARKit landscape (image_width × image_height)
    }

    @State private var corner: Corner = .TL
    @State private var photoIdx: Int = 0
    @State private var taps: [Corner: [Tap]] = [.TL: [], .TR: [], .BR: [], .BL: []]
    @State private var inviando = false
    @State private var errore: String?

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()

            VStack(spacing: 12) {
                header
                cornerPicker
                photoArea
                thumbnailStrip
                actionButtons
            }
            .padding(.bottom, 16)
        }
        .alert("Errore", isPresented: Binding(get: { errore != nil }, set: { if !$0 { errore = nil } })) {
            Button("OK") { errore = nil }
        } message: { Text(errore ?? "") }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Annulla") { onAnnulla() }
                .foregroundColor(Theme.navy)
            Spacer()
            Text("Tappa i 4 angoli")
                .font(Theme.Typo.title(17))
                .foregroundStyle(Theme.navy)
            Spacer()
            Text(progressoText).font(Theme.Typo.caption()).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var progressoText: String {
        let ok = Corner.allCases.filter { (taps[$0] ?? []).count >= 2 }.count
        return "\(ok)/4"
    }

    // MARK: - Corner picker

    private var cornerPicker: some View {
        HStack(spacing: 6) {
            ForEach(Corner.allCases) { c in
                Button { corner = c } label: {
                    HStack(spacing: 4) {
                        Text(c.rawValue).font(.system(size: 12, weight: .bold))
                        Text("(\((taps[c] ?? []).count))").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(c == corner ? Theme.yellow : Theme.navy)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(c == corner ? Theme.navy : Theme.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Theme.hair2, lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Photo area (con tap)

    private var photoArea: some View {
        GeometryReader { geo in
            let photo = currentPhoto
            ZStack {
                Color.black
                if let p = photo,
                   let img = UIImage(contentsOfFile: p.localImageURL.path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay(GeometryReader { g in
                            // Marker per i tap di questa foto, per ciascun corner
                            ForEach(Corner.allCases) { c in
                                ForEach(taps[c] ?? []) { tap in
                                    if tap.photoIdx == p.orderIndex {
                                        let pt = landscapeToScreen(
                                            landscape: tap.pxLandscape,
                                            displayedSize: g.size, photo: p)
                                        marker(corner: c, isCurrent: c == corner)
                                            .position(pt)
                                    }
                                }
                            }
                        })
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { v in
                                    addTap(at: v.location, displayedSize: geo.size, photo: p)
                                }
                        )
                } else {
                    Text("Nessuna foto").foregroundStyle(Theme.muted)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 16)
    }

    private func marker(corner: Corner, isCurrent: Bool) -> some View {
        ZStack {
            Circle().stroke(Theme.white, lineWidth: 2).frame(width: 22, height: 22)
            Circle().fill(isCurrent ? Theme.yellow : Theme.navy).frame(width: 14, height: 14)
            Text(corner.rawValue)
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(isCurrent ? Theme.navy : Theme.white)
        }
        .shadow(color: .black.opacity(0.45), radius: 3)
    }

    // MARK: - Thumb strip (sceglie foto)

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(rilievo.frameCatturati) { p in
                    Button { photoIdx = p.orderIndex } label: {
                        if let data = p.thumbnailImage, let ui = UIImage(data: data) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(p.orderIndex == photoIdx ? Theme.yellow : Theme.hair, lineWidth: p.orderIndex == photoIdx ? 3 : 1)
                                )
                                .overlay(alignment: .topTrailing) {
                                    let n = tapsOnPhoto(p.orderIndex)
                                    if n > 0 {
                                        Text("\(n)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(Theme.navy)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Theme.yellow, in: Capsule())
                                            .padding(4)
                                    }
                                }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 80)
    }

    private func tapsOnPhoto(_ idx: Int) -> Int {
        Corner.allCases.reduce(0) { acc, c in
            acc + (taps[c] ?? []).filter { $0.photoIdx == idx }.count
        }
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        VStack(spacing: 8) {
            BrandButton(title: "Rimuovi tap angolo corrente (\(corner.rawValue))",
                        systemImage: "arrow.uturn.backward", kind: .ghost) {
                if !(taps[corner] ?? []).isEmpty { taps[corner]?.removeLast() }
            }
            .disabled((taps[corner] ?? []).isEmpty)
            .opacity((taps[corner] ?? []).isEmpty ? 0.4 : 1)

            BrandButton(title: inviando ? "Calcolo…" : "Calcola piano + ortorettifica",
                        systemImage: "checkmark.circle.fill", kind: .primary) {
                Task { await inviaAlBackend() }
            }
            .disabled(!puoiInviare || inviando)
        }
        .padding(.horizontal, 16)
    }

    private var puoiInviare: Bool {
        Corner.allCases.allSatisfy { (c) in
            let ts = taps[c] ?? []
            // ≥ 2 tap su foto diverse
            return Set(ts.map { $0.photoIdx }).count >= 2
        }
    }

    private var currentPhoto: CapturedFacadePhoto? {
        rilievo.frameCatturati.first(where: { $0.orderIndex == photoIdx })
            ?? rilievo.frameCatturati.first
    }

    // MARK: - Tap → pixel landscape ARKit

    /// Mappa una posizione di tap sullo schermo al pixel nel frame ARKit landscape
    /// (image_width × image_height da metadata). Tiene conto del fit aspect e
    /// della rotazione iOS .right (JPEG portrait ↔ K landscape).
    private func addTap(at screenPt: CGPoint, displayedSize: CGSize, photo: CapturedFacadePhoto) {
        let landscape = screenToLandscape(screenPt: screenPt,
                                          displayedSize: displayedSize,
                                          photo: photo)
        guard let landscape else { return }
        var arr = taps[corner] ?? []
        // Rimuovi eventuale tap precedente sulla stessa foto (1 tap per (corner, foto))
        arr.removeAll { $0.photoIdx == photo.orderIndex }
        arr.append(Tap(photoIdx: photo.orderIndex, pxLandscape: landscape))
        taps[corner] = arr
    }

    private func screenToLandscape(screenPt: CGPoint, displayedSize: CGSize, photo: CapturedFacadePhoto) -> CGPoint? {
        // 1) screen → pixel nella foto-JPEG portrait (perché iOS salva .right).
        // L'immagine viene mostrata con scaledToFit, quindi serve calcolare l'aspect.
        let imgW = CGFloat(photo.imageHeight)   // JPEG portrait è H×W vs landscape W×H
        let imgH = CGFloat(photo.imageWidth)
        // wait, il JPEG ha sue dimensioni native: se metadata dice landscape 4032×3024
        // ma il JPEG salvato è ruotato a portrait, allora UIImage size = 3024×4032.
        // Lo confermiamo con loadFromPath sopra. Per essere robusti, ricostruiamo
        // le dimensioni del file qua via UIImage.
        guard let ui = UIImage(contentsOfFile: photo.localImageURL.path) else { return nil }
        let jpegW = ui.size.width
        let jpegH = ui.size.height
        // Aspect fit dentro displayedSize.
        let scale = min(displayedSize.width / jpegW, displayedSize.height / jpegH)
        let renderedW = jpegW * scale
        let renderedH = jpegH * scale
        let offsetX = (displayedSize.width - renderedW) / 2
        let offsetY = (displayedSize.height - renderedH) / 2
        let x_in = (screenPt.x - offsetX) / scale
        let y_in = (screenPt.y - offsetY) / scale
        guard x_in >= 0, y_in >= 0, x_in <= jpegW, y_in <= jpegH else { return nil }

        // 2) JPEG portrait → landscape ARKit. Il backend applica
        //    cv2.ROTATE_90_CLOCKWISE quando rileva mismatch buffer↔K. Replichiamo
        //    qui la stessa rotazione (dst_landscape coords).
        //    Se le dimensioni JPEG sono già landscape (= metadata), niente rotazione.
        let metaW = CGFloat(photo.imageWidth)
        let metaH = CGFloat(photo.imageHeight)
        if abs(jpegW - metaW) < 1 && abs(jpegH - metaH) < 1 {
            return CGPoint(x: x_in, y: y_in)
        }
        if abs(jpegW - metaH) < 1 && abs(jpegH - metaW) < 1 {
            // ROTATE_90_CW: src(x,y) → dst(H_src - 1 - y, x)
            let lx = jpegH - 1 - y_in
            let ly = x_in
            return CGPoint(x: lx, y: ly)
        }
        // Mismatch sconosciuto: assumo identità ma segnalo
        return CGPoint(x: x_in, y: y_in)
        _ = imgW; _ = imgH
    }

    /// Inversa: pixel landscape ARKit → punto sullo schermo (per disegnare i marker).
    private func landscapeToScreen(landscape: CGPoint, displayedSize: CGSize, photo: CapturedFacadePhoto) -> CGPoint {
        guard let ui = UIImage(contentsOfFile: photo.localImageURL.path) else {
            return .zero
        }
        let jpegW = ui.size.width
        let jpegH = ui.size.height
        let metaW = CGFloat(photo.imageWidth)
        let metaH = CGFloat(photo.imageHeight)
        // landscape → jpeg coords (inverse della rotazione di sopra)
        var x_in: CGFloat = landscape.x
        var y_in: CGFloat = landscape.y
        if abs(jpegW - metaH) < 1 && abs(jpegH - metaW) < 1 {
            // landscape (lx, ly) → src (x, y): from `lx = jpegH - 1 - y`, `ly = x`
            x_in = landscape.y
            y_in = jpegH - 1 - landscape.x
        }
        let scale = min(displayedSize.width / jpegW, displayedSize.height / jpegH)
        let renderedW = jpegW * scale
        let renderedH = jpegH * scale
        let offsetX = (displayedSize.width - renderedW) / 2
        let offsetY = (displayedSize.height - renderedH) / 2
        return CGPoint(x: offsetX + x_in * scale, y: offsetY + y_in * scale)
    }

    // MARK: - Backend submit

    private func inviaAlBackend() async {
        inviando = true
        defer { inviando = false }
        do {
            let corners = Corner.allCases.map { c -> [BackendAPIClient.CornerTap] in
                (taps[c] ?? []).map {
                    BackendAPIClient.CornerTap(
                        photo_order_index: $0.photoIdx,
                        pixel: [Double($0.pxLandscape.x), Double($0.pxLandscape.y)]
                    )
                }
            }
            let req = BackendAPIClient.TriangulateRequest(corners: corners)
            _ = try await BackendAPIClient.shared.computeWallPlane(sessionId: sessionId, request: req)
            let res = try await BackendAPIClient.shared.orthorectify(sessionId: sessionId, pixelsPerMeter: 150)
            let url = res.composite_url.flatMap(URL.init(string:))
            await MainActor.run { onCompletato(url) }
        } catch {
            await MainActor.run { errore = error.localizedDescription }
        }
    }
}

