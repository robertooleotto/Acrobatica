import SwiftUI

/// Indicatore pitch stile orizzonte artificiale: scala dei gradi con riferimento
/// centrale fisso. In modalità colonna usa il primo scatto come zero operativo.
struct PitchLadderOverlay: View {
    let pitchDeg: Float
    var referencePitchDeg: Float?
    var rollDeg: Float = 0
    var referenceRollDeg: Float?
    var rollToleranceDeg: Float = 2
    var yawRad: Float = 0
    var referenceYawRad: Float?
    var yawToleranceDeg: Float = 2
    var stepDeg: Float = 6

    private let pixelsPerDegree: CGFloat = 5.5
    private let visibleRangeDeg: Float = 32

    var body: some View {
        GeometryReader { geo in
            let ladderSize = CGSize(width: min(geo.size.width * 0.72, 320), height: 260)
            ZStack {
                ladder(size: ladderSize)
                yawRibbon
                    .offset(y: -ladderSize.height / 2 + 26)
                rollArc
                    .offset(y: -ladderSize.height / 2 + 70)
                centerPointer
            }
            .frame(width: ladderSize.width, height: ladderSize.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .allowsHitTesting(false)
        }
    }

    private var displayPitch: Float {
        if let referencePitchDeg {
            return pitchDeg - referencePitchDeg
        }
        return pitchDeg
    }

    private var rollDeltaDeg: Float {
        guard let referenceRollDeg else { return nearestRollErrorDeg }
        var d = referenceRollDeg - rollDeg
        while d < -180 { d += 360 }
        while d > 180 { d -= 360 }
        return d
    }

    private var nearestRollErrorDeg: Float {
        let candidates: [Float] = [0, 90, -90, 180, -180]
        let nearest = candidates.min(by: { abs($0 - rollDeg) < abs($1 - rollDeg) }) ?? 0
        return rollDeg - nearest
    }

    private var rollAligned: Bool {
        abs(rollDeltaDeg) <= rollToleranceDeg
    }

    private var yawDeltaDeg: Float? {
        guard let referenceYawRad else { return nil }
        var d = (referenceYawRad - yawRad) * 180 / .pi
        while d < -180 { d += 360 }
        while d > 180 { d -= 360 }
        return d
    }

    private var yawAligned: Bool {
        guard let yawDeltaDeg else { return false }
        return abs(yawDeltaDeg) <= yawToleranceDeg
    }

    private var alignmentColor: Color {
        yawAligned && rollAligned ? Theme.success : Theme.yellow
    }

    private func ladder(size: CGSize) -> some View {
        Canvas { ctx, canvasSize in
            let cx = canvasSize.width / 2
            let cy = canvasSize.height / 2
            let start = floor(displayPitch - visibleRangeDeg)
            let end = ceil(displayPitch + visibleRangeDeg)

            var deg = start
            while deg <= end {
                let rounded = Int(deg)
                guard rounded.isMultiple(of: 5) else {
                    deg += 1
                    continue
                }

                let y = cy + CGFloat(displayPitch - deg) * pixelsPerDegree
                if y < -20 || y > canvasSize.height + 20 {
                    deg += 1
                    continue
                }

                let isZero = rounded == 0
                let isStep = stepDeg > 0 && abs(Float(rounded)).truncatingRemainder(dividingBy: stepDeg) < 0.01
                let color = isZero ? Theme.yellow : (isStep ? Theme.success : .white.opacity(0.62))
                let lineWidth: CGFloat = isZero ? 3 : (isStep ? 2 : 1)
                let tickWidth: CGFloat = isZero ? 112 : (isStep ? 86 : 58)
                let gap: CGFloat = 18

                var left = Path()
                left.move(to: CGPoint(x: cx - gap - tickWidth / 2, y: y))
                left.addLine(to: CGPoint(x: cx - gap, y: y))
                ctx.stroke(left, with: .color(color), lineWidth: lineWidth)

                var right = Path()
                right.move(to: CGPoint(x: cx + gap, y: y))
                right.addLine(to: CGPoint(x: cx + gap + tickWidth / 2, y: y))
                ctx.stroke(right, with: .color(color), lineWidth: lineWidth)

                if rounded != 0 {
                    let text = Text("\(rounded > 0 ? "+" : "")\(rounded)")
                        .font(.system(size: isStep ? 12 : 10, weight: isStep ? .semibold : .medium, design: .monospaced))
                        .foregroundColor(color)
                    ctx.draw(text, at: CGPoint(x: cx - gap - tickWidth / 2 - 20, y: y), anchor: .center)
                    ctx.draw(text, at: CGPoint(x: cx + gap + tickWidth / 2 + 20, y: y), anchor: .center)
                }

                deg += 1
            }
        }
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.10))
                .blur(radius: 0.5)
        )
    }

    private var centerPointer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(alignmentColor)
                    .frame(width: 58, height: 3)
                Text(String(format: "%+.0f°", displayPitch))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(alignmentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.45), in: Capsule())
                Capsule()
                    .fill(alignmentColor)
                    .frame(width: 58, height: 3)
            }
            .rotationEffect(.degrees(Double(-rollDeltaDeg)))
            PitchTriangle()
                .fill(alignmentColor)
                .frame(width: 12, height: 8)
        }
        .shadow(color: alignmentColor.opacity(0.65), radius: 8)
    }

    private var yawRibbon: some View {
        let delta = yawDeltaDeg
        let clamped = CGFloat(max(-12, min(12, delta ?? 0)))
        return ZStack {
            Capsule()
                .fill(Color.black.opacity(0.42))
                .frame(width: 170, height: 34)
                .overlay(
                    Capsule()
                        .stroke(yawAligned ? Theme.success.opacity(0.9) : Color.white.opacity(0.28), lineWidth: 1)
                )

            HStack(spacing: 4) {
                Image(systemName: yawAligned ? "checkmark.circle.fill" : "location.north.line.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(yawAligned ? Theme.success : Theme.yellow)
                Text(delta.map { String(format: "%+.1f°", $0) } ?? "Yaw")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(yawAligned ? Theme.success : .white)
            }

            Capsule()
                .fill(yawAligned ? Theme.success : Theme.yellow)
                .frame(width: yawAligned ? 5 : 3, height: 26)
                .offset(x: clamped * 5)
                .shadow(color: (yawAligned ? Theme.success : Theme.yellow).opacity(0.75), radius: 7)
        }
    }

    private var rollArc: some View {
        let tickColor = rollAligned ? Theme.success : Color.white.opacity(0.72)
        return ZStack {
            ForEach([-12, -6, 0, 6, 12], id: \.self) { deg in
                Capsule()
                    .fill(deg == 0 ? alignmentColor : tickColor)
                    .frame(width: deg == 0 ? 3 : 2, height: deg == 0 ? 18 : 12)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(deg)))
            }

            PitchTriangle()
                .fill(alignmentColor)
                .frame(width: 13, height: 9)
                .offset(y: -45)
                .rotationEffect(.degrees(Double(-rollDeltaDeg)))

            Text(String(format: "%+.1f°", rollDeltaDeg))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(rollAligned ? Theme.success : .white.opacity(0.88))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.42), in: Capsule())
                .offset(y: -14)
        }
        .frame(width: 130, height: 76)
    }
}

private struct PitchTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}
