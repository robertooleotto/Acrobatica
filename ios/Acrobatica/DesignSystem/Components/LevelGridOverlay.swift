import SwiftUI

/// Overlay sopra l'AR live: griglia 3×3 (rule of thirds) + livella a bolla.
/// Aiuta l'operatore a tenere il telefono dritto in **roll** (sempre) e a
/// allineare verticali del palazzo a una colonna della griglia.
///
/// Note di design:
/// - **Roll only**: il pitch può essere qualsiasi (l'operatore inclina volutamente
///   il telefono in alto per coprire la facciata). Quindi la livella mostra solo
///   l'errore di torsione (roll) → "dritto" = roll ≈ ±90° (landscape) o ±0° (portrait).
/// - Griglia molto sottile per non distrarre, colore con leggero glow.
struct LevelGridOverlay: View {
    /// Roll del telefono in gradi (ARKit eulerAngles.z * 180/π).
    let rollDeg: Float
    /// Se true, la livella è "verde" entro 1° di tolleranza.
    var levelToleranceDeg: Float = 1.5

    var body: some View {
        ZStack {
            grid
            levelLine
                .padding(.top, 120)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Grid 3×3

    private var grid: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                // Verticali a 1/3 e 2/3
                p.move(to: .init(x: w/3, y: 0));   p.addLine(to: .init(x: w/3, y: h))
                p.move(to: .init(x: 2*w/3, y: 0)); p.addLine(to: .init(x: 2*w/3, y: h))
                // Orizzontali a 1/3 e 2/3
                p.move(to: .init(x: 0, y: h/3));   p.addLine(to: .init(x: w, y: h/3))
                p.move(to: .init(x: 0, y: 2*h/3)); p.addLine(to: .init(x: w, y: 2*h/3))
            }
            .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 0.5, dash: [6, 6]))
        }
    }

    // MARK: - Livella roll

    /// Errore di roll dal "dritto" più vicino: 0°, ±90°, 180°.
    /// Valori positivi = telefono ruotato verso destra; negativi = sinistra.
    private var rollError: Float {
        // Trova il riferimento "dritto" più vicino (0, ±90, ±180)
        let candidates: [Float] = [0, 90, -90, 180, -180]
        let nearest = candidates.min(by: { abs($0 - rollDeg) < abs($1 - rollDeg) }) ?? 0
        return rollDeg - nearest
    }

    private var isLevel: Bool { abs(rollError) <= levelToleranceDeg }

    /// Livella stile design pulito: SOLO una linea centrale che ruota col phone
    /// e diventa verde quando dritta. Niente cerchio, niente label gradi.
    private var levelLine: some View {
        Capsule()
            .fill(isLevel ? Theme.success : .white.opacity(0.85))
            .frame(width: 140, height: 3)
            .rotationEffect(.degrees(Double(-rollError)))
            .shadow(color: (isLevel ? Theme.success : .black).opacity(isLevel ? 0.7 : 0.4),
                    radius: isLevel ? 8 : 2)
            .animation(.easeOut(duration: 0.12), value: isLevel)
    }
}


/// Livella minimale: SOLO la linea centrale (niente griglia 3×3). Ruota col roll
/// e diventa verde in bolla. Usa il riferimento "dritto" più vicino (0/±90/180)
/// quindi è corretta sia in portrait che in landscape — NON va ruotata dall'esterno.
struct LevelLineOverlay: View {
    let rollDeg: Float
    var toleranceDeg: Float = 1.5

    private var rollError: Float {
        let candidates: [Float] = [0, 90, -90, 180, -180]
        let nearest = candidates.min(by: { abs($0 - rollDeg) < abs($1 - rollDeg) }) ?? 0
        return rollDeg - nearest
    }
    private var isLevel: Bool { abs(rollError) <= toleranceDeg }

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.5)).frame(width: 5, height: 5)
            Capsule()
                .fill(isLevel ? Theme.success : .white.opacity(0.85))
                .frame(width: 170, height: 3)
                .rotationEffect(.degrees(Double(-rollError)))
                .shadow(color: (isLevel ? Theme.success : .black).opacity(isLevel ? 0.7 : 0.4),
                        radius: isLevel ? 8 : 2)
                .animation(.easeOut(duration: 0.12), value: isLevel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }
}
