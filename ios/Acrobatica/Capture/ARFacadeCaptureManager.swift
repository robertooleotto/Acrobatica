import Foundation
import ARKit
import RealityKit
import UIKit
import simd
import CoreImage
import QuartzCore

/// Stato di qualità di un piano rilevato (solo per piani esistenti / `ARPlaneAnchor`).
enum PlaneQuality {
    case hidden
    case unstable
    case stable
}

/// Tipo di hit risultante dal raycast centrale del reticle.
///
/// - `none`: nessun piano sotto il reticle (per ARKit né un anchor né una stima).
/// - `estimated`: ARKit ha solo una **stima** di un piano (es. da feature points sparsi),
///   non un anchor stabile. Tipico su facciate lontane / muri lisci.
/// - `existing`: ARKit ha un `ARPlaneAnchor` reale (geometria stimata, normale, extent).
///   Comune su muri vicini in interni.
enum PlaneHitType {
    case none
    case estimated
    case existing
}

@MainActor
final class ARFacadeCaptureManager: NSObject, ObservableObject {

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published private(set) var trackingState: String = "limited.initializing"
    @Published private(set) var hasLidar: Bool = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var verticalPlanesCount: Int = 0
    @Published private(set) var planeUnderReticleId: UUID? = nil
    @Published private(set) var planeUnderReticleQuality: PlaneQuality = .hidden
    @Published private(set) var planeHitType: PlaneHitType = .none
    @Published private(set) var distanceFromLastCaptureM: Float? = nil
    /// Baseline "smussata" (media mobile su ~1s). Più affidabile dell'istantaneo
    /// per il chip UI: filtra il jitter di ARKit su scene povere di feature, dove
    /// la stima posizionale può flickerare di metri tra frame consecutivi anche
    /// se trackingState=normal.
    @Published private(set) var distanceFromLastCaptureSmoothedM: Float? = nil
    /// Buffer dei campioni di distanza degli ultimi N tick (250ms × 4 = 1s).
    private var distanceSamples: [Float] = []
    private let distanceSampleCount = 4

    /// LiDAR mesh: disabilitato di default. Deve restare opzionale.
    var enableSceneReconstructionMesh: Bool = false

    /// Soglie filtro qualità piano.
    var minimumPlaneAreaM2: Float = 0.15
    var stabilityWindowSec: TimeInterval = 0.8

    private var lastCaptureWorldPos: SIMD3<Float>? = nil
    private var verticalPlaneIds: Set<UUID> = []
    /// Stato interno per piano (stabilità, area, centro). Niente rendering — solo
    /// tracking per `computePlaneQuality` e per il reticle "locked" nella UI.
    private var planeOverlayParts: [UUID: PlaneOverlayParts] = [:]
    private var raycastTimer: Timer? = nil
    // Ultima `worldTransform` del raycast `.estimatedPlane` verticale sotto reticle
    // e quando l'abbiamo aggiornata. Usata come fallback per la normale del muro
    // quando non c'è un ARPlaneAnchor stabile (tipico su facciate lontane / muri lisci).
    private var lastEstimatedPlaneTransform: simd_float4x4? = nil
    private var lastEstimatedPlaneAt: TimeInterval = 0
    private let estimatedPlaneFreshnessSec: TimeInterval = 0.6

    private let ciContext = CIContext(options: nil)

    private struct PlaneOverlayParts {
        var lastBoundaryArea: Float
        var lastVerticesCount: Int
        var lastCenter: SIMD3<Float>
        var lastSignificantChange: TimeInterval
    }

    override init() {
        super.init()
        arView.session.delegate = self
        startSession()
        startReticleRaycastTimer()
    }

    deinit {
        raycastTimer?.invalidate()
    }

    // MARK: - Session

    func startSession() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical, .horizontal]
        config.environmentTexturing = .none
        config.worldAlignment = .gravity

        if enableSceneReconstructionMesh,
           ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        // Forza la lente wide (1x, ~26mm) anziché il teleobiettivo.
        // `recommendedVideoFormatForHighResolutionFrameCapturing` su iPhone Pro tende a scegliere
        // il telephoto (2x/3x) per via della risoluzione massima, dando l'effetto "zoom" indesiderato.
        // Qui prendiamo la risoluzione massima TRA i formati wide-angle.
        let wideFormats = ARWorldTrackingConfiguration.supportedVideoFormats.filter {
            $0.captureDeviceType == .builtInWideAngleCamera
        }
        if let bestWide = wideFormats.max(by: {
            $0.imageResolution.width * $0.imageResolution.height
                < $1.imageResolution.width * $1.imageResolution.height
        }) {
            config.videoFormat = bestWide
            let r = bestWide.imageResolution
            print("[ARFacadeCapture] using WIDE format: \(bestWide.captureDeviceType.rawValue) \(Int(r.width))×\(Int(r.height)) @\(Int(bestWide.framesPerSecond))fps")
        } else if let hires = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = hires
            print("[ARFacadeCapture] using HIRES fallback format: \(hires.captureDeviceType.rawValue)")
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func resetSession() {
        arView.session.pause()
        planeOverlayParts.removeAll()
        verticalPlaneIds.removeAll()
        verticalPlanesCount = 0
        planeUnderReticleId = nil
        planeUnderReticleQuality = .hidden
        lastCaptureWorldPos = nil
        distanceFromLastCaptureM = nil
        trackingState = "limited.initializing"
        startSession()
    }

    // MARK: - Capture

    func captureHighResolutionPhoto(orderIndex: Int) async throws -> CapturedFacadePhoto {
        guard !isBusy else { throw CaptureError.busy }
        isBusy = true
        defer { isBusy = false }

        // NB: NON usiamo `captureHighResolutionFrame` perché su iPhone Pro+ Apple può
        // dirottarci verso il teleobiettivo (più pixel ma campo visivo stretto = "zoom 2x").
        // Usiamo invece il currentFrame del feed video, che rispetta il videoFormat scelto
        // (wide-angle 1x). Risoluzione minore ma campo visivo corretto.
        guard let frame = arView.session.currentFrame else {
            throw CaptureError.noFrame
        }

        let pixelBuffer = frame.capturedImage
        let camera = frame.camera
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw CaptureError.imageConversionFailed
        }

        // Saviamo il buffer in ARKit landscape NATIVO (orientation .up) — i pixel
        // coincidono con il frame in cui K (camera_intrinsics) è espressa, quindi
        // niente più mismatch buffer↔K nel backend. iOS Photos.app mostrerà
        // le foto "di lato" ma per il pipeline di rilievo è il formato corretto.
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        guard let jpeg = uiImage.jpegData(compressionQuality: 0.88) else {
            throw CaptureError.encodingFailed
        }

        let filename = "photo_\(UUID().uuidString.prefix(8)).jpg"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(filename)
        try jpeg.write(to: url)

        let thumbnailData = uiImage
            .preparingThumbnail(of: CGSize(width: 256, height: 256))?
            .jpegData(compressionQuality: 0.7)

        let euler = SIMD3<Float>(
            camera.eulerAngles.x * 180 / .pi,
            camera.eulerAngles.y * 180 / .pi,
            camera.eulerAngles.z * 180 / .pi
        )

        let camTranslation = camera.transform.columns.3
        let camPos = SIMD3<Float>(camTranslation.x, camTranslation.y, camTranslation.z)

        if let last = lastCaptureWorldPos {
            distanceFromLastCaptureM = simd_length(camPos - last)
        } else {
            distanceFromLastCaptureM = 0
        }
        lastCaptureWorldPos = camPos
        // Reset dei campioni: parte da zero dopo ogni cattura.
        distanceSamples.removeAll()
        distanceFromLastCaptureSmoothedM = 0

        // Normale del muro per il keystone full-plane (verticali + orizzontali).
        // Due fonti, in ordine di preferenza:
        //  A) ARPlaneAnchor verticale STABILE sotto il reticle — più accurata.
        //  B) Fallback `.estimatedPlane`: stima da feature points sparsi, l'unica
        //     che funziona su facciate lontane / muri lisci dove ARKit non crea
        //     un anchor. La accettiamo solo se aggiornata di recente (freshness),
        //     altrimenti meglio nessuna normale che una stantia.
        // In entrambi i casi la normale è la colonna 1 della transform del piano
        // (Y locale del plane = normale, già in world coords).
        var wallNormal: SIMD3<Float>? = nil
        if planeUnderReticleQuality == .stable,
           let id = planeUnderReticleId,
           let plane = frame.anchors.first(where: { $0.identifier == id }) as? ARPlaneAnchor,
           plane.alignment == .vertical {
            let n = plane.transform.columns.1
            wallNormal = simd_normalize(SIMD3<Float>(n.x, n.y, n.z))
        } else if let est = lastEstimatedPlaneTransform,
                  (CACurrentMediaTime() - lastEstimatedPlaneAt) < estimatedPlaneFreshnessSec {
            let n = est.columns.1
            wallNormal = simd_normalize(SIMD3<Float>(n.x, n.y, n.z))
        }

        return CapturedFacadePhoto(
            localImageURL: url,
            thumbnailImage: thumbnailData,
            orderIndex: orderIndex,
            timestampMs: Date().timeIntervalSince1970 * 1000,
            imageWidth: CVPixelBufferGetWidth(pixelBuffer),
            imageHeight: CVPixelBufferGetHeight(pixelBuffer),
            cameraTransform: camera.transform,
            cameraIntrinsics: camera.intrinsics,
            eulerAnglesDeg: euler,
            trackingState: trackingStateString(camera.trackingState),
            wallNormalWorld: wallNormal
        )
    }

    enum CaptureError: LocalizedError {
        case busy, noFrame, imageConversionFailed, encodingFailed
        var errorDescription: String? {
            switch self {
            case .busy: return "Cattura già in corso"
            case .noFrame: return "Nessun frame disponibile da ARKit"
            case .imageConversionFailed: return "Conversione immagine fallita"
            case .encodingFailed: return "Encoding JPEG fallito"
            }
        }
    }

    private func trackingStateString(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited.initializing"
            case .excessiveMotion: return "limited.excessiveMotion"
            case .insufficientFeatures: return "limited.insufficientFeatures"
            case .relocalizing: return "limited.relocalizing"
            @unknown default: return "limited.unknown"
            }
        @unknown default: return "unknown"
        }
    }

    // MARK: - Plane tracking (no rendering — solo stato per la quality del reticle)

    fileprivate func trackPlane(_ plane: ARPlaneAnchor) {
        guard plane.alignment == .vertical else { return }
        let verts = plane.geometry.boundaryVertices
        let area = polygonAreaInXZ(verts)
        let center = SIMD3<Float>(plane.center.x, plane.center.y, plane.center.z)
        let now = CACurrentMediaTime()

        if var parts = planeOverlayParts[plane.identifier] {
            let areaChange = parts.lastBoundaryArea > 0
                ? abs(area - parts.lastBoundaryArea) / parts.lastBoundaryArea
                : 1
            let vertsChange = abs(verts.count - parts.lastVerticesCount)
            let centerChange = simd_length(center - parts.lastCenter)
            let significantChange = areaChange > 0.05 || vertsChange >= 2 || centerChange >= 0.05
            if significantChange { parts.lastSignificantChange = now }
            parts.lastBoundaryArea = area
            parts.lastVerticesCount = verts.count
            parts.lastCenter = center
            planeOverlayParts[plane.identifier] = parts
        } else {
            planeOverlayParts[plane.identifier] = PlaneOverlayParts(
                lastBoundaryArea: area,
                lastVerticesCount: verts.count,
                lastCenter: center,
                lastSignificantChange: now
            )
        }

        if planeUnderReticleId == plane.identifier {
            let quality = computePlaneQuality(plane: plane, parts: planeOverlayParts[plane.identifier]!,
                                              now: now, area: area)
            planeUnderReticleQuality = quality
        }
    }

    fileprivate func untrackPlane(_ plane: ARPlaneAnchor) {
        planeOverlayParts.removeValue(forKey: plane.identifier)
    }

    // MARK: - Quality + visibility

    private func computePlaneQuality(plane: ARPlaneAnchor, parts: PlaneOverlayParts, now: TimeInterval, area: Float) -> PlaneQuality {
        if planeUnderReticleId != plane.identifier { return .hidden }
        if trackingState != "normal" { return .hidden }
        if area < minimumPlaneAreaM2 { return .hidden }
        // Normale del piano deve guardare verso la camera.
        if let frame = arView.session.currentFrame {
            let T = plane.transform
            let normal = simd_normalize(SIMD3<Float>(T.columns.1.x, T.columns.1.y, T.columns.1.z))
            let pPos = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
            let cTrans = frame.camera.transform.columns.3
            let cPos = SIMD3<Float>(cTrans.x, cTrans.y, cTrans.z)
            let toCam = simd_normalize(cPos - pPos)
            if simd_dot(normal, toCam) < 0 { return .hidden }
        }
        let elapsed = now - parts.lastSignificantChange
        return elapsed >= stabilityWindowSec ? .stable : .unstable
    }

    /// Forza ricalcolo della qualità per i piani tracciati (es. quando cambia
    /// `planeUnderReticleId`).
    private func refreshAllPlaneVisibility() {
        for (id, _) in planeOverlayParts {
            guard let plane = arView.session.currentFrame?.anchors.first(where: { $0.identifier == id }) as? ARPlaneAnchor else { continue }
            trackPlane(plane)
        }
    }

    /// Area di un poligono nel piano XZ via shoelace.
    private func polygonAreaInXZ(_ verts: [SIMD3<Float>]) -> Float {
        guard verts.count >= 3 else { return 0 }
        var sum: Float = 0
        for i in 0..<verts.count {
            let a = verts[i], b = verts[(i + 1) % verts.count]
            sum += a.x * b.z - b.x * a.z
        }
        return abs(sum) / 2
    }

    // MARK: - Reticle raycast

    private func startReticleRaycastTimer() {
        raycastTimer?.invalidate()
        raycastTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickReticleRaycast() }
        }
    }

    private func tickReticleRaycast() {
        guard arView.bounds.width > 0, arView.bounds.height > 0 else { return }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)

        let previousId = planeUnderReticleId
        var newHitType: PlaneHitType = .none
        var newPlaneId: UUID? = nil

        // 1) Primo tentativo: piano "esistente" (ARPlaneAnchor con geometria stimata).
        if let q = arView.makeRaycastQuery(from: screenCenter,
                                            allowing: .existingPlaneGeometry,
                                            alignment: .vertical),
           let hit = arView.session.raycast(q).first,
           let plane = hit.anchor as? ARPlaneAnchor,
           plane.alignment == .vertical {
            newHitType = .existing
            newPlaneId = plane.identifier
        }
        // 2) Fallback: stima di un piano da feature points (no anchor stabile).
        //    Utile su facciate lontane / muri lisci dove ARKit non crea un ARPlaneAnchor.
        else if let q = arView.makeRaycastQuery(from: screenCenter,
                                                 allowing: .estimatedPlane,
                                                 alignment: .vertical),
                let estHit = arView.session.raycast(q).first {
            newHitType = .estimated
            newPlaneId = nil
            // Salva la stima — la useremo come normale del muro alla cattura.
            lastEstimatedPlaneTransform = estHit.worldTransform
            lastEstimatedPlaneAt = CACurrentMediaTime()
        }

        if planeHitType != newHitType { planeHitType = newHitType }
        if planeUnderReticleId != newPlaneId { planeUnderReticleId = newPlaneId }
        if newHitType != .existing {
            // Senza ARPlaneAnchor non ha senso parlare di "stable/unstable".
            if planeUnderReticleQuality != .hidden { planeUnderReticleQuality = .hidden }
        }

        // Se il piano sotto reticle è cambiato, forza refresh degli overlay
        // (il vecchio deve sparire, il nuovo deve apparire).
        if previousId != planeUnderReticleId {
            refreshAllPlaneVisibility()
        }

        if let last = lastCaptureWorldPos,
           let frame = arView.session.currentFrame {
            let cam = frame.camera.transform.columns.3
            let now = SIMD3<Float>(cam.x, cam.y, cam.z)
            let d = simd_length(now - last)
            distanceFromLastCaptureM = d
            // Media mobile su distanceSampleCount campioni (~1s a 250ms/tick).
            // Filtra il jitter di ARKit su scene povere di feature dove la stima
            // posizionale flickera anche se trackingState=normal.
            distanceSamples.append(d)
            if distanceSamples.count > distanceSampleCount { distanceSamples.removeFirst() }
            let avg = distanceSamples.reduce(0, +) / Float(distanceSamples.count)
            // "Conservativo": prendi il MINIMO dei campioni invece della media, così
            // un singolo picco non rende il chip verde — serve baseline stabile.
            let conservative = distanceSamples.min() ?? d
            distanceFromLastCaptureSmoothedM = min(avg, conservative)
        }
    }
}

// MARK: - ARSessionDelegate

extension ARFacadeCaptureManager: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor in
            self.trackingState = self.trackingStateString(camera.trackingState)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let verticalPlanes = anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .vertical }
        guard !verticalPlanes.isEmpty else { return }
        Task { @MainActor in
            for plane in verticalPlanes {
                self.verticalPlaneIds.insert(plane.identifier)
                self.trackPlane(plane)
            }
            self.verticalPlanesCount = self.verticalPlaneIds.count
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let verticalPlanes = anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .vertical }
        guard !verticalPlanes.isEmpty else { return }
        Task { @MainActor in
            for plane in verticalPlanes { self.trackPlane(plane) }
            self.verticalPlanesCount = self.verticalPlaneIds.count
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let verticalPlanes = anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .vertical }
        guard !verticalPlanes.isEmpty else { return }
        Task { @MainActor in
            for plane in verticalPlanes {
                self.verticalPlaneIds.remove(plane.identifier)
                self.untrackPlane(plane)
                if self.planeUnderReticleId == plane.identifier {
                    self.planeUnderReticleId = nil
                    self.planeUnderReticleQuality = .hidden
                }
            }
            self.verticalPlanesCount = self.verticalPlaneIds.count
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.trackingState = "session.failed" }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in self.trackingState = "session.interrupted" }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.trackingState = "session.interruptionEnded"
            self.resetSession()
        }
    }
}
