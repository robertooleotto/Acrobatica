import Foundation
import simd

/// Logica condivisa per:
///  - trovare la "foto già scattata" più simile alla posa corrente (per ghost)
///  - decidere se è il momento di scattare il prossimo frame (per badge "Pronto")
///
/// Tutti pure functions/static — facili da chiamare da SmartGhostOverlay e
/// CatturaARView senza duplicare math.
enum CaptureMatchAnalyzer {

    // MARK: - Soglie

    /// Distanza massima accettabile della camera dal best-match (m).
    static let maxPositionDeltaM: Float = 2.0
    /// Angolo massimo di look fra current e best-match (deg).
    static let maxLookAngleDeltaDeg: Float = 45.0
    /// Tolleranza di roll per il livello (deg).
    static let rollToleranceDeg: Float = 3.0
    /// Pan minimo dal best-match per evitare scatti praticamente identici (deg).
    static let minPanDeg: Float = 5.0
    /// Range fallback se la FOV reale non è nota (es. ARKit non ancora pronto).
    /// Tarato per iPhone wide-angle 1× (FOV ~42°).
    static let optimalPanRangeFallbackDeg: ClosedRange<Float> = 8.0...28.0

    /// Range ottimale in funzione della FOV verticale della lente corrente.
    /// Formula: tra il 30% e il 65% della FOV → overlap fra 35% e 70%.
    /// Es. wide 1× FOV 42° → 13°-27°. Ultra-wide 0.5× FOV ~90° → 27°-58°.
    static func optimalPanRangeDeg(forVerticalFOVDeg fov: Float?) -> ClosedRange<Float> {
        guard let fov = fov, fov > 10 else { return optimalPanRangeFallbackDeg }
        let lo = fov * 0.30
        let hi = fov * 0.65
        return lo...hi
    }

    // MARK: - Best match

    /// Per ogni frame, score = Δpos_m + Δangolo_deg/25. Restituisce il migliore
    /// (entro le soglie) o nil se nessuno è abbastanza vicino.
    static func bestMatch(frames: [CapturedFacadePhoto],
                          currentPose: simd_float4x4) -> (frame: CapturedFacadePhoto, pose: simd_float4x4)? {
        let currPos = SIMD3<Float>(currentPose.columns.3.x,
                                   currentPose.columns.3.y,
                                   currentPose.columns.3.z)
        let currLook = -simd_normalize(SIMD3<Float>(currentPose.columns.2.x,
                                                    currentPose.columns.2.y,
                                                    currentPose.columns.2.z))
        var best: (CapturedFacadePhoto, simd_float4x4)? = nil
        var bestScore: Float = .infinity
        for f in frames {
            let p = f.cameraTransformMatrix
            let pos = SIMD3<Float>(p.columns.3.x, p.columns.3.y, p.columns.3.z)
            let look = -simd_normalize(SIMD3<Float>(p.columns.2.x, p.columns.2.y, p.columns.2.z))
            let dPos = simd_length(pos - currPos)
            let dot = max(-1.0, min(1.0, simd_dot(look, currLook)))
            let dAngleDeg = acos(dot) * 180 / .pi
            if dPos > maxPositionDeltaM || dAngleDeg > maxLookAngleDeltaDeg { continue }
            let score = dPos + dAngleDeg / 25.0
            if score < bestScore { bestScore = score; best = (f, p) }
        }
        return best
    }

    /// Angolo di pan (deg) tra due pose, considerando solo look-direction.
    static func panAngleDeg(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let la = -simd_normalize(SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let lb = -simd_normalize(SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        let dot = max(-1.0, min(1.0, simd_dot(la, lb)))
        return acos(dot) * 180 / .pi
    }

    // MARK: - Readiness

    enum Readiness {
        case primoScatto                 // 0 foto → sempre pronto
        case prontoOverlapBuono           // match trovato + pan ottimale + livello → SCATTA
        case continuaPan                  // match trovato ma pan ancora piccolo (sotto optimalRange)
        case tooFar                       // hai esagerato col pan dall'ultimo match
        case nonLivellato                 // roll fuori tolleranza
        case nessunMatch                  // niente match (raramente — solo se eri MOLTO lontano)

        var label: String {
            switch self {
            case .primoScatto:        return "Pronto: primo scatto"
            case .prontoOverlapBuono: return "Pronto: scatta"
            case .continuaPan:        return "Continua a muoverti…"
            case .tooFar:             return "Troppo lontano: torna indietro"
            case .nonLivellato:       return "Drizza il telefono"
            case .nessunMatch:        return "Posizione fuori range"
            }
        }
        var isReady: Bool {
            switch self {
            case .primoScatto, .prontoOverlapBuono: return true
            default: return false
            }
        }
    }

    /// Numeri grezzi del match più vicino (per debug HUD).
    struct MatchDebugInfo {
        let panDeg: Float
        let positionDeltaM: Float
    }

    static func matchDebug(frames: [CapturedFacadePhoto],
                           currentPose: simd_float4x4?) -> MatchDebugInfo? {
        guard let curr = currentPose, let best = bestMatch(frames: frames, currentPose: curr) else {
            return nil
        }
        let currPos = SIMD3<Float>(curr.columns.3.x, curr.columns.3.y, curr.columns.3.z)
        let bestPos = SIMD3<Float>(best.pose.columns.3.x, best.pose.columns.3.y, best.pose.columns.3.z)
        return MatchDebugInfo(
            panDeg: panAngleDeg(best.pose, curr),
            positionDeltaM: simd_length(bestPos - currPos)
        )
    }

    static func readiness(frames: [CapturedFacadePhoto],
                          currentPose: simd_float4x4?,
                          currentRollDeg: Float,
                          verticalFovDeg: Float? = nil) -> Readiness {
        if frames.isEmpty { return .primoScatto }
        guard let curr = currentPose else { return .nessunMatch }

        // Livello: roll ≈ 0, ±90, ±180 entro tolleranza
        let candidates: [Float] = [0, 90, -90, 180, -180]
        let nearest = candidates.min { abs($0 - currentRollDeg) < abs($1 - currentRollDeg) } ?? 0
        if abs(currentRollDeg - nearest) > rollToleranceDeg { return .nonLivellato }

        // Match
        guard let best = bestMatch(frames: frames, currentPose: curr) else {
            return .nessunMatch
        }
        let pan = panAngleDeg(best.pose, curr)
        let range = optimalPanRangeDeg(forVerticalFOVDeg: verticalFovDeg)
        if pan < minPanDeg            { return .continuaPan }
        if pan < range.lowerBound     { return .continuaPan }
        if pan > range.upperBound     { return .tooFar }
        return .prontoOverlapBuono
    }
}
