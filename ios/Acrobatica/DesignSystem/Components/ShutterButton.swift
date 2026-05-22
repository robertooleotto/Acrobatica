import SwiftUI

/// Pulsante di scatto iOS-style: cerchio esterno + bottone giallo centrale.
struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(Theme.yellow)
                    .frame(width: 62, height: 62)
                    .shadow(color: Theme.yellow.opacity(0.4), radius: 10)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Reticle / mira centrale per l'AR view.
/// È un semplice indicatore di mira: ARKit non aggancia piani affidabilmente
/// a distanza palazzo, quindi niente stato "locked/pending" — colore neutro fisso.
struct ReticleOverlay: View {
    var body: some View {
        let color: Color = Theme.yellow.opacity(0.85)
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) * 0.55
            ZStack {
                // Cornice angolare stile camera
                cornerMarks
                    .frame(width: s, height: s)
                    .foregroundColor(color)
                // Crosshair centrale
                Path { p in
                    let c = CGPoint(x: geo.size.width/2, y: geo.size.height/2)
                    p.move(to: CGPoint(x: c.x - 14, y: c.y)); p.addLine(to: CGPoint(x: c.x + 14, y: c.y))
                    p.move(to: CGPoint(x: c.x, y: c.y - 14)); p.addLine(to: CGPoint(x: c.x, y: c.y + 14))
                }
                .stroke(color, lineWidth: 1.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var cornerMarks: some View {
        GeometryReader { g in
            let s = g.size.width
            let l: CGFloat = 22
            let w: CGFloat = 3
            Path { p in
                // top-left
                p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: l, y: 0))
                // top-right
                p.move(to: CGPoint(x: s - l, y: 0)); p.addLine(to: CGPoint(x: s, y: 0)); p.addLine(to: CGPoint(x: s, y: l))
                // bottom-right
                p.move(to: CGPoint(x: s, y: s - l)); p.addLine(to: CGPoint(x: s, y: s)); p.addLine(to: CGPoint(x: s - l, y: s))
                // bottom-left
                p.move(to: CGPoint(x: l, y: s)); p.addLine(to: CGPoint(x: 0, y: s)); p.addLine(to: CGPoint(x: 0, y: s - l))
            }
            .stroke(style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
    }
}
