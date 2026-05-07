import SwiftUI
import UIKit

struct RaddrizzamentoView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    @State private var raddrizzata: UIImage?

    private var fotoOriginale: UIImage? {
        stato.fotoData.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("3.2 · Raddrizzamento prospettico")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text("Trascina i 4 angoli sul perimetro della facciata")
                    .font(.title3.bold())

                if let img = fotoOriginale {
                    InteractiveCornersView(image: img, stato: stato)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Nessuna foto disponibile")
                        .foregroundStyle(.secondary)
                }

                Button {
                    applica()
                } label: {
                    Label("Applica raddrizzamento", systemImage: "wand.and.rays")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(fotoOriginale == nil)

                if let r = raddrizzata {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ANTEPRIMA RADDRIZZATA").font(.caption.bold()).foregroundStyle(.secondary)
                        Image(uiImage: r)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("\(Int(stato.fotoRaddrizzataWidthPx)) × \(Int(stato.fotoRaddrizzataHeightPx)) px")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("PROSSIMI MIGLIORAMENTI").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("• Auto-detect angoli con VNDetectRectanglesRequest")
                    Text("• Snap su linee verticali/orizzontali")
                    Text("• Zoom locale durante il drag")
                }
                .font(.caption)
            }
            .padding()
        }
        .navigationTitle("Raddrizzamento")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Avanti") { onAvanti() }
                    .buttonStyle(.borderedProminent)
                    .disabled(stato.fotoRaddrizzataData == nil)
            }
        }
    }

    private func applica() {
        guard let data = stato.fotoData else { return }
        guard let result = PerspectiveCorrector.raddrizza(
            jpegData: data,
            tl: stato.angoloTL,
            tr: stato.angoloTR,
            br: stato.angoloBR,
            bl: stato.angoloBL
        ) else { return }
        stato.fotoRaddrizzataData = result.jpeg
        stato.fotoRaddrizzataWidthPx = result.widthPx
        stato.fotoRaddrizzataHeightPx = result.heightPx
        raddrizzata = UIImage(data: result.jpeg)
    }
}

private struct InteractiveCornersView: View {
    let image: UIImage
    @Bindable var stato: SopralluogoState

    private let handleRadius: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let display = displayRect(in: proxy.size)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: display.width, height: display.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                // Trapezoide
                Path { p in
                    let pts = [stato.angoloTL, stato.angoloTR, stato.angoloBR, stato.angoloBL]
                        .map { norm2view($0, in: display, parent: proxy.size) }
                    p.move(to: pts[0])
                    for i in 1..<pts.count { p.addLine(to: pts[i]) }
                    p.closeSubpath()
                }
                .stroke(Color.accentColor, lineWidth: 2)

                // 4 manopole
                handle(\.angoloTL, in: display, parent: proxy.size)
                handle(\.angoloTR, in: display, parent: proxy.size)
                handle(\.angoloBR, in: display, parent: proxy.size)
                handle(\.angoloBL, in: display, parent: proxy.size)
            }
        }
        .aspectRatio(image.size.width / max(1, image.size.height), contentMode: .fit)
    }

    private func displayRect(in size: CGSize) -> CGSize {
        let imgRatio = image.size.width / max(1, image.size.height)
        let containerRatio = size.width / max(1, size.height)
        if imgRatio > containerRatio {
            return CGSize(width: size.width, height: size.width / imgRatio)
        } else {
            return CGSize(width: size.height * imgRatio, height: size.height)
        }
    }

    private func norm2view(_ p: CGPoint, in display: CGSize, parent: CGSize) -> CGPoint {
        let originX = (parent.width - display.width) / 2
        let originY = (parent.height - display.height) / 2
        return CGPoint(x: originX + p.x * display.width,
                       y: originY + p.y * display.height)
    }

    private func view2norm(_ p: CGPoint, in display: CGSize, parent: CGSize) -> CGPoint {
        let originX = (parent.width - display.width) / 2
        let originY = (parent.height - display.height) / 2
        let nx = (p.x - originX) / max(1, display.width)
        let ny = (p.y - originY) / max(1, display.height)
        return CGPoint(x: min(1, max(0, nx)), y: min(1, max(0, ny)))
    }

    @ViewBuilder
    private func handle(_ kp: ReferenceWritableKeyPath<SopralluogoState, CGPoint>,
                        in display: CGSize,
                        parent: CGSize) -> some View {
        let pos = norm2view(stato[keyPath: kp], in: display, parent: parent)
        Circle()
            .fill(Color.accentColor)
            .frame(width: handleRadius * 2, height: handleRadius * 2)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .position(pos)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        stato[keyPath: kp] = view2norm(value.location, in: display, parent: parent)
                    }
            )
    }
}
