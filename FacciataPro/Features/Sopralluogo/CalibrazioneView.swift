import SwiftUI
import UIKit

struct CalibrazioneView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    @State private var misuraCmText: String = ""
    @State private var overrideManuale: Bool = false
    @State private var larghezzaText: String = ""
    @State private var altezzaText: String = ""

    private var fotoRaddrizzata: UIImage? {
        stato.fotoRaddrizzataData.flatMap { UIImage(data: $0) }
    }

    private var lunghezzaSegmentoPx: Double {
        let dxNorm = Double(stato.segmentoEnd.x - stato.segmentoStart.x)
        let dyNorm = Double(stato.segmentoEnd.y - stato.segmentoStart.y)
        let dxPx = dxNorm * stato.fotoRaddrizzataWidthPx
        let dyPx = dyNorm * stato.fotoRaddrizzataHeightPx
        return (dxPx * dxPx + dyPx * dyPx).squareRoot()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("3.3 · Calibrazione dimensionale")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text("Misura un riferimento noto")
                    .font(.title3.bold())

                Text("Trascina i due punti su un oggetto di misura reale nota (es. porta = 90 cm).")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let img = fotoRaddrizzata {
                    SegmentoInteractiveView(image: img, stato: stato)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Nessuna foto raddrizzata. Torna allo step precedente.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Lunghezza segmento")
                    Spacer()
                    Text("\(Int(lunghezzaSegmentoPx)) px").foregroundStyle(.secondary)
                }
                .padding()
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Text("Misura reale")
                    Spacer()
                    TextField("cm", text: $misuraCmText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }
                .padding()
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    calcola()
                } label: {
                    Label("Calcola dimensioni", systemImage: "ruler")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(fotoRaddrizzata == nil || misuraCmText.isEmpty)

                VStack(alignment: .leading, spacing: 8) {
                    Text("DIMENSIONI STIMATE").font(.caption.bold()).foregroundStyle(.secondary)
                    HStack { Text("pixel/cm"); Spacer(); Text(stato.pixelPerCm > 0 ? String(format: "%.2f", stato.pixelPerCm) : "—") }
                    HStack { Text("Larghezza"); Spacer(); Text(stato.larghezzaM > 0 ? String(format: "%.2f m", stato.larghezzaM) : "—") }
                    HStack { Text("Altezza"); Spacer(); Text(stato.altezzaM > 0 ? String(format: "%.2f m", stato.altezzaM) : "—") }
                    HStack {
                        Text("Superficie lorda").bold()
                        Spacer()
                        Text(stato.superficieLordaMq > 0 ? String(format: "%.2f m²", stato.superficieLordaMq) : "—").bold()
                    }
                }
                .padding()
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Toggle("Override manuale", isOn: $overrideManuale)
                if overrideManuale {
                    HStack {
                        TextField("Larghezza (m)", text: $larghezzaText)
                            .keyboardType(.decimalPad)
                        TextField("Altezza (m)", text: $altezzaText)
                            .keyboardType(.decimalPad)
                    }
                    Button("Applica override") { applicaOverride() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle("Calibrazione")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if stato.misuraSegmentoCm > 0 && misuraCmText.isEmpty {
                misuraCmText = String(format: "%g", stato.misuraSegmentoCm)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Avanti") { onAvanti() }
                    .buttonStyle(.borderedProminent)
                    .disabled(stato.larghezzaM <= 0 || stato.altezzaM <= 0)
            }
        }
    }

    private func calcola() {
        let cm = Double(misuraCmText.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard cm > 0, lunghezzaSegmentoPx > 0 else { return }
        stato.misuraSegmentoCm = cm
        let pxPerCm = lunghezzaSegmentoPx / cm
        stato.pixelPerCm = pxPerCm
        stato.larghezzaM = (stato.fotoRaddrizzataWidthPx / pxPerCm) / 100
        stato.altezzaM = (stato.fotoRaddrizzataHeightPx / pxPerCm) / 100
    }

    private func applicaOverride() {
        let l = Double(larghezzaText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let h = Double(altezzaText.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard l > 0, h > 0 else { return }
        stato.larghezzaM = l
        stato.altezzaM = h
        if stato.fotoRaddrizzataWidthPx > 0 {
            stato.pixelPerCm = stato.fotoRaddrizzataWidthPx / (l * 100)
        }
    }
}

private struct SegmentoInteractiveView: View {
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

                Path { p in
                    let a = norm2view(stato.segmentoStart, in: display, parent: proxy.size)
                    let b = norm2view(stato.segmentoEnd, in: display, parent: proxy.size)
                    p.move(to: a)
                    p.addLine(to: b)
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                handle(\.segmentoStart, in: display, parent: proxy.size, color: .yellow)
                handle(\.segmentoEnd, in: display, parent: proxy.size, color: .yellow)
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
                        parent: CGSize,
                        color: Color) -> some View {
        let pos = norm2view(stato[keyPath: kp], in: display, parent: parent)
        Circle()
            .fill(color)
            .frame(width: handleRadius * 2, height: handleRadius * 2)
            .overlay(Circle().stroke(.black, lineWidth: 2))
            .position(pos)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        stato[keyPath: kp] = view2norm(value.location, in: display, parent: parent)
                    }
            )
    }
}
