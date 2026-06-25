import SwiftUI
import simd

/// "Smart ghost" overlay sopra l'AR live: trova la foto già scattata più
/// SIMILE alla posa corrente, mostra una sua striscia sul lato dell'overlap.
///
/// Cambio rispetto alla v1: prima ghostava SEMPRE l'ultima foto. Problema:
/// dopo una passata bottom→top, l'ultima è in alto al tetto; se inizio una
/// nuova passata dalla base, il ghost era inutile (= foto del tetto).
///
/// Adesso: per ogni live frame cerca la foto già scattata con la posa più
/// vicina (combinazione di Δposizione 3D e Δangolo di sguardo). Solo se trova
/// un match "abbastanza buono" mostra il ghost; altrimenti niente (vista pulita).
///
/// Logica della striscia (dopo aver scelto il "best match"):
///   pan UP    (sguardo si alza rispetto al match)  → striscia BASSA con TOP del match
///   pan DOWN  → striscia in ALTO con BOTTOM
///   pan RIGHT (yaw verso destra) → striscia a SINISTRA con DESTRA
///   pan LEFT  → striscia a DESTRA con SINISTRA
struct SmartGhostOverlay: View {
    /// Tutte le foto già scattate. Il componente sceglie la più simile alla posa corrente.
    let frames: [CapturedFacadePhoto]
    let currentPose: simd_float4x4?

    /// Larghezza/altezza della striscia (frazione del viewfinder).
    var stripFraction: CGFloat = 0.28

    /// Quale porzione della foto precedente mostrare (frazione del lato della
    /// thumbnail). Una striscia del 35% sembra il giusto compromesso fra
    /// utilità e ingombro visivo.
    var thumbnailSliceFraction: CGFloat = 0.35

    /// Opacità della striscia ghost (0…1). Default 1.0 = pieno per debug visivo;
    /// in produzione abbassare a ~0.35 per non coprire il live.
    var opacity: Double = 1.0

    enum Direction { case up, down, left, right, none }

    var body: some View {
        GeometryReader { geo in
            if let curr = currentPose,
               let best = CaptureMatchAnalyzer.bestMatch(frames: frames, currentPose: curr),
               let data = best.frame.thumbnailImage,
               let ui = UIImage(data: data),
               let direction = panDirection(matchPose: best.pose, currentPose: curr),
               direction != .none {
                let rot = displayRotationDeg(forPhotoPose: best.pose)
                stripView(direction: direction, image: ui, frame: geo.size, rotationDeg: rot)
            }
        }
        .allowsHitTesting(false)
    }

    /// Angolo (gradi) per ruotare la thumbnail così che il "mondo-su" (gravità)
    /// punti verso l'alto del display — uguale al frame live (ARView auto-rotate).
    private func displayRotationDeg(forPhotoPose pose: simd_float4x4) -> Double {
        let R = matrix_float3x3(
            SIMD3<Float>(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
            SIMD3<Float>(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
            SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        )
        // world-up in camera frame = R^T @ (0,1,0) = riga 1 di R = colonna 0 di R^T
        // simd: R.transpose * (0,1,0). Componenti = (R.col1.x, R.col1.y, R.col1.z) — wait, NO.
        // R^T @ v: prendo riga i di R^T che è colonna i di R^T = riga i di R.
        // R^T @ (0,1,0) = (R[0][1], R[1][1], R[2][1]) = colonna 1 di R^T → equivalente.
        // Più semplice: simd_mul col vettore (in simd, matrix * vector usa post-mul col-major).
        let upWorld = SIMD3<Float>(0, 1, 0)
        let upCam = simd_mul(R.transpose, upWorld)
        // Camera frame: +x destra immagine, +y su immagine, +z verso viewer.
        // Image plane: y down. world-up in image = (upCam.x, -upCam.y)
        // Angolo da image-top (0,-1): atan2(image.x, -image.y) = atan2(upCam.x, upCam.y)
        let rad = atan2(upCam.x, upCam.y)
        return -Double(rad) * 180.0 / .pi   // SwiftUI rotationEffect: positivo = orario
    }

    private func panDirection(matchPose match: simd_float4x4, currentPose curr: simd_float4x4) -> Direction? {
        let matchLook = -SIMD3<Float>(match.columns.2.x, match.columns.2.y, match.columns.2.z)
        let currLook  = -SIMD3<Float>(curr.columns.2.x,  curr.columns.2.y,  curr.columns.2.z)
        let dy = currLook.y - matchLook.y          // > 0 = look si alza
        let matchH = simd_normalize(SIMD3<Float>(matchLook.x, 0, matchLook.z))
        let currH  = simd_normalize(SIMD3<Float>(currLook.x,  0, currLook.z))
        let dx = matchH.x * currH.z - matchH.z * currH.x

        let threshold: Float = 0.05    // ~3° di rotazione
        let absDx = abs(dx), absDy = abs(dy)
        if max(absDx, absDy) < threshold { return Direction.none }
        if absDy > absDx { return dy > 0 ? .up : .down }
        else             { return dx > 0 ? .right : .left }
    }

    @ViewBuilder
    private func stripView(direction: Direction, image: UIImage, frame: CGSize, rotationDeg: Double) -> some View {
        // Se ruoto di ±90°, le dimensioni native dell'immagine (W×H) si scambiano
        // di fatto: una thumbnail landscape (es. 256×144) ruotata 90° riempie un
        // box "portrait" 144×256. SwiftUI Image rotata mantiene il frame originale,
        // quindi serve uno scale per riempire correttamente.
        let needsSwap = abs(rotationDeg.truncatingRemainder(dividingBy: 180)) > 45
        let scale: CGFloat = needsSwap
            ? max(image.size.width / image.size.height, image.size.height / image.size.width)
            : 1.0
        let thumb = Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .rotationEffect(.degrees(rotationDeg))
            .scaleEffect(scale)

        switch direction {
        case .up:
            // Ghost in basso, mostra TOP slice della foto precedente
            HStack(spacing: 0) {
                Color.clear
            }
            .overlay(alignment: .bottom) {
                thumb
                    .frame(width: frame.width, height: frame.height * stripFraction, alignment: .top)
                    .clipped()
                    .opacity(opacity)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.yellow.opacity(0.85)).frame(height: 1.5)
                    }
            }
        case .down:
            Color.clear.overlay(alignment: .top) {
                thumb
                    .frame(width: frame.width, height: frame.height * stripFraction, alignment: .bottom)
                    .clipped()
                    .opacity(opacity)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.yellow.opacity(0.85)).frame(height: 1.5)
                    }
            }
        case .right:
            // Ghost a sinistra, mostra DESTRA della foto precedente
            Color.clear.overlay(alignment: .leading) {
                thumb
                    .frame(width: frame.width * stripFraction, height: frame.height, alignment: .trailing)
                    .clipped()
                    .opacity(opacity)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Theme.yellow.opacity(0.85)).frame(width: 1.5)
                    }
            }
        case .left:
            Color.clear.overlay(alignment: .trailing) {
                thumb
                    .frame(width: frame.width * stripFraction, height: frame.height, alignment: .leading)
                    .clipped()
                    .opacity(opacity)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.yellow.opacity(0.85)).frame(width: 1.5)
                    }
            }
        case .none:
            EmptyView()
        }
    }
}
