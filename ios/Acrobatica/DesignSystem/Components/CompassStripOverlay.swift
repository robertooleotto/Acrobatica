import SwiftUI

/// Compass strip stile iPhone Camera Pro: nastro orizzontale di 60° visibili,
/// indicatore centrale fisso, tick ogni 10° con label ogni 30°.
///
/// Lo yaw è quello ARKit (eulerAngles.y), allineato al nord dalla sessione
/// `.gravityAndHeading`. Il riferimento del primo scatto continua a indicare
/// se la camera sta guardando lo stesso muro.
///
/// Lettura: il numero al centro è il bearing corrente. I tick scorrono sotto
/// l'indicatore quando ruoti il telefono.
struct CompassStripOverlay: View {
    /// Yaw corrente in radianti (ARKit `eulerAngles.y`).
    let yawRad: Float
    /// Yaw fissato al primo scatto. Se presente, diventa il riferimento da seguire.
    var referenceYawRad: Float?
    var yawToleranceDeg: Float = 0.7

    /// Quanti gradi vediamo nel nastro a sinistra/destra del centro.
    var visibleRangeDeg: Float = 30

    /// Pixel per grado nel render (controlla quanto "veloce" scorrono i tick).
    var pixelsPerDegree: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 40, 240)
            ZStack {
                strip(width: width)
                if referenceYawRad != nil {
                    referenceMarker(width: width)
                }
                centerIndicator
                alignmentDot
            }
            .frame(width: width, height: 46)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    /// Yaw normalizzato in [0, 360).
    private var yawDeg: Float {
        var d = -yawRad * 180 / .pi    // segno: yaw ARKit positivo = ruoti a sinistra
        d = d.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    private var referenceYawDeg: Float? {
        guard let referenceYawRad else { return nil }
        var d = -referenceYawRad * 180 / .pi
        d = d.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    private var referenceDeltaDeg: Float? {
        guard let ref = referenceYawDeg else { return nil }
        var d = ref - yawDeg
        while d < -180 { d += 360 }
        while d > 180 { d -= 360 }
        return d
    }

    private var isAligned: Bool {
        guard let referenceDeltaDeg else { return false }
        return abs(referenceDeltaDeg) <= yawToleranceDeg
    }

    /// Strip a tacche pure (zero label gradi). Solo tick visibili che scorrono
    /// sotto l'indicatore centrale fisso. L'utente vede a colpo d'occhio:
    /// tacca lontana a destra del centro → devo ruotare a destra per allinearmi.
    private func strip(width: CGFloat) -> some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let startDeg = floor(yawDeg - visibleRangeDeg - 5)
            let endDeg   = ceil(yawDeg + visibleRangeDeg + 5)
            var d = startDeg
            while d <= endDeg {
                let offset = CGFloat(d - yawDeg) * pixelsPerDegree
                let x = cx + offset
                if x < -10 || x > size.width + 10 { d += 1; continue }
                let isMajor = Int(d).isMultiple(of: 30)
                let isMid   = Int(d).isMultiple(of: 10)
                let h: CGFloat = isMajor ? 18 : (isMid ? 12 : 6)
                let y0: CGFloat = (26 - h) / 2
                ctx.stroke(
                    Path { p in
                        p.move(to: .init(x: x, y: y0))
                        p.addLine(to: .init(x: x, y: y0 + h))
                    },
                    with: .color(.white.opacity(isMajor ? 0.90 : (isMid ? 0.55 : 0.30))),
                    lineWidth: isMajor ? 1.5 : 1
                )
                d += 1
            }
        }
    }

    private func referenceMarker(width: CGFloat) -> some View {
        let delta = referenceDeltaDeg ?? 0
        let clamped = max(-visibleRangeDeg, min(visibleRangeDeg, delta))
        let x = CGFloat(clamped) * pixelsPerDegree
        return VStack(spacing: 3) {
            Circle()
                .fill(isAligned ? Theme.success : Theme.yellow)
                .frame(width: isAligned ? 10 : 8, height: isAligned ? 10 : 8)
            Capsule()
                .fill(isAligned ? Theme.success : Theme.yellow.opacity(0.98))
                .frame(width: isAligned ? 6 : 4, height: isAligned ? 34 : 30)
        }
            .offset(x: x, y: 7)
            .shadow(color: (isAligned ? Theme.success : Theme.yellow).opacity(0.9), radius: isAligned ? 12 : 5)
            .animation(.easeOut(duration: 0.12), value: isAligned)
    }

    /// Indicatore centrale: triangolo giallo che punta in basso sui tick.
    /// Stile bussola iPhone Camera senza label.
    private var centerIndicator: some View {
        Triangle()
            .fill(isAligned ? Theme.success : Theme.yellow)
            .frame(width: 10, height: 8)
            .offset(y: -16)
            .shadow(color: (isAligned ? Theme.success : Theme.yellow).opacity(0.65), radius: isAligned ? 7 : 3)
            .animation(.easeOut(duration: 0.12), value: isAligned)
    }

    private var alignmentDot: some View {
        Circle()
            .strokeBorder(isAligned ? Theme.success : Color.white.opacity(0.75), lineWidth: isAligned ? 3 : 2)
            .background(Circle().fill(isAligned ? Theme.success.opacity(0.18) : Color.black.opacity(0.35)))
            .frame(width: 18, height: 18)
            .offset(y: 23)
            .shadow(color: (isAligned ? Theme.success : Color.black).opacity(0.65), radius: isAligned ? 10 : 3)
            .animation(.easeOut(duration: 0.12), value: isAligned)
    }
}

/// Piccolo triangolo che punta in BASSO (apex a destra del path inferiore).
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}
