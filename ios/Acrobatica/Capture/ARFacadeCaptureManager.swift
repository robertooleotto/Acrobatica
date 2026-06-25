import Foundation
import ARKit
import AVFoundation
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

/// Tempo di scatto (otturatore) selezionabile dall'operatore. Preset veloci
/// anti-mosso: più alto il denominatore, più congela il movimento (ma più ISO).
/// Default molto veloce (1/1000) per la cattura in camminata.
enum ShutterSpeed: Int, CaseIterable, Identifiable {
    case s250 = 250, s500 = 500, s1000 = 1000, s2000 = 2000
    var id: Int { rawValue }
    var label: String { "1/\(rawValue)" }
    var duration: CMTime { CMTime(value: 1, timescale: Int32(rawValue)) }
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
    @Published private(set) var cameraControlsLocked: Bool = false
    @Published private(set) var cameraControlsStatus: String = "camera.auto"

    /// Tempo di scatto scelto dall'operatore (default veloce 1/1000 anti-mosso).
    /// Cambiarlo riapplica l'esposizione custom se la camera è bloccata.
    @Published var shutterSpeed: ShutterSpeed = .s1000 {
        didSet { if cameraControlsLocked { lockCameraControlsForFacadeCapture() } }
    }
    /// Compensazione esposizione scelta dall'operatore (EV, −2…+2). Regola la
    /// luminosità target: <0 più scuro, >0 più chiaro. Applicata live (auto) e
    /// preservata al blocco (incide sull'ISO custom).
    @Published var exposureBiasEV: Float = 0 {
        didSet {
            applyExposureBias()
            if cameraControlsLocked { lockCameraControlsForFacadeCapture() }
        }
    }
    /// Rotazione (in gradi) della camera rispetto all'ultima cattura. Insieme a
    /// `distanceFromLastCaptureM` guida il trigger della modalità Auto.
    @Published private(set) var rotationFromLastCaptureDeg: Float = 0
    private var lastCaptureOrientation: simd_quatf? = nil
    @Published private(set) var verticalPlanesCount: Int = 0
    @Published private(set) var planeUnderReticleId: UUID? = nil
    @Published private(set) var planeUnderReticleQuality: PlaneQuality = .hidden
    @Published private(set) var planeHitType: PlaneHitType = .none
    @Published private(set) var distanceFromLastCaptureM: Float? = nil
    /// Pose corrente della camera (camera→world). Aggiornato a ogni frame ARKit.
    /// Usato dall'UI per: livella (roll), ghost direzionale, debugging.
    @Published private(set) var currentPose: simd_float4x4? = nil
    /// Roll corrente in gradi (live, da ARKit eulerAngles.z).
    @Published private(set) var currentRollDeg: Float = 0
    /// Pitch corrente in gradi (live, da ARKit eulerAngles.x).
    @Published private(set) var currentPitchDeg: Float = 0
    /// Yaw corrente in radianti (live, da ARKit eulerAngles.y). Riferimento:
    /// posa di partenza della sessione (.gravity worldAlignment).
    @Published private(set) var currentYawRad: Float = 0
    /// Quando è partita l'ARKit session corrente (in unix-epoch ms). Le foto
    /// scattate PRIMA di questo timestamp hanno coordinate `camera_transform`
    /// in un world frame ARKit ORMAI INVALIDATO — vanno escluse da ogni
    /// matching geometrico (smart-ghost, readiness, ortho).
    @Published private(set) var sessionStartedAtMs: Double = 0
    /// FOV verticale corrente in gradi, calcolata da intrinsics + image height
    /// del frame ARKit live. Cambia con device/lens (wide vs ultra-wide vs
    /// telephoto). Serve a `CaptureMatchAnalyzer` per calibrare la soglia
    /// "Pronto" in funzione della lente reale.
    @Published private(set) var currentVerticalFOVDeg: Float = 0
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
    private var lastPoseUpdateAt: TimeInterval = 0

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
        // Rilevamento piani DISATTIVATO: il flusso pose-prior usa solo le POSE
        // della camera, non gli ARPlaneAnchor. Toglierlo riduce molto il carico
        // CPU/termico (e la batteria) durante catture lunghe.
        config.planeDetection = []
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
        // Risoluzione MEDIA, non massima: ~1920px di larghezza bastano per la
        // ricostruzione (i test mostrano che 1500px regge) e l'ISP scalda molto
        // meno che al formato massimo. Scelgo il formato wide più piccolo con
        // larghezza ≥ targetWidth; se non esiste, il più grande disponibile.
        let targetWidth: CGFloat = 1920
        let wideFormats = ARWorldTrackingConfiguration.supportedVideoFormats.filter {
            $0.captureDeviceType == .builtInWideAngleCamera
        }
        let atLeastTarget = wideFormats.filter { $0.imageResolution.width >= targetWidth }
        let chosen = atLeastTarget.min(by: { $0.imageResolution.width < $1.imageResolution.width })
            ?? wideFormats.max(by: { $0.imageResolution.width < $1.imageResolution.width })
        if let fmt = chosen {
            config.videoFormat = fmt
            let r = fmt.imageResolution
            print("[ARFacadeCapture] using WIDE format (medium): \(Int(r.width))×\(Int(r.height)) @\(Int(fmt.framesPerSecond))fps")
        } else if let hires = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = hires
            print("[ARFacadeCapture] using HIRES fallback format: \(hires.captureDeviceType.rawValue)")
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        cameraControlsLocked = false
        cameraControlsStatus = "camera.auto"
        // Niente auto-lock: l'esposizione resta in auto (live) finché l'operatore
        // non punta la luce e blocca manualmente (lockCameraControlsForFacadeCapture).
        // Tag della sessione: tutte le foto già scattate PRIMA di questo
        // momento hanno camera_transform in un world frame diverso (ARKit
        // resetta l'origine ad ogni startSession) e vanno escluse dai
        // calcoli geometrici.
        sessionStartedAtMs = Date().timeIntervalSince1970 * 1000
    }

    /// Ferma ARKit e la fotocamera (es. al "Fine"): spegne il feed video → il
    /// telefono smette di scaldare mentre gli upload proseguono in background.
    func pauseSession() {
        arView.session.pause()
        raycastTimer?.invalidate(); raycastTimer = nil
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

        if !cameraControlsLocked {
            lockCameraControlsForFacadeCapture()
        }

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
        lastCaptureOrientation = simd_quatf(camera.transform)
        rotationFromLastCaptureDeg = 0
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

    // MARK: - Camera controls

    /// Sblocca i controlli camera → torna in auto (live metering) così l'operatore
    /// può ri-puntare la luce e ribloccare.
    func unlockCameraControls() {
        guard let device = preferredCaptureDevice() else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            cameraControlsLocked = false
            cameraControlsStatus = "camera.auto"
        } catch {
            print("[ARFacadeCapture] unlock failed: \(error.localizedDescription)")
        }
    }

    /// Applica la compensazione EV all'esposizione automatica (live, anche da
    /// sbloccato). Clampata al range supportato dal device.
    func applyExposureBias() {
        guard let device = preferredCaptureDevice() else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let ev = min(max(exposureBiasEV, device.minExposureTargetBias),
                         device.maxExposureTargetBias)
            device.setExposureTargetBias(ev, completionHandler: nil)
        } catch {
            print("[ARFacadeCapture] exposure bias failed: \(error.localizedDescription)")
        }
    }

    private func preferredCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
    }

    /// Blocca esposizione, bilanciamento del bianco e focus sul valore corrente.
    /// ARKit possiede la sessione camera: su alcuni device iOS può rifiutare una
    /// parte del lock, quindi lo trattiamo come best-effort e mostriamo lo stato.
    func lockCameraControlsForFacadeCapture() {
        guard let device = preferredCaptureDevice() else {
            cameraControlsLocked = false
            cameraControlsStatus = "camera.unavailable"
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // Otturatore veloce anti-mosso: imposto un'esposizione CUSTOM con
            // durata limitata (≤ facadeMaxShutterDuration) e ISO che compensa per
            // mantenere la luminosità corrente. Fallback su .locked se non supportato.
            if device.isExposureModeSupported(.custom) {
                let minD = device.activeFormat.minExposureDuration
                let maxD = device.activeFormat.maxExposureDuration
                // durata target = otturatore scelto dall'operatore, clampato al device
                var dur = CMTimeMinimum(shutterSpeed.duration, maxD)
                dur = CMTimeMaximum(dur, minD)
                // ISO brightness-preserving: ISO_new = ISO_cur * (durata_cur / durata_target)
                // poi modulato dalla compensazione EV scelta: ×2^EV.
                let curSec = CMTimeGetSeconds(device.exposureDuration)
                let tgtSec = CMTimeGetSeconds(dur)
                var iso = device.iso
                if curSec > 0, tgtSec > 0 {
                    iso = device.iso * Float(curSec / tgtSec)
                }
                iso *= powf(2, exposureBiasEV)
                iso = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                device.setExposureModeCustom(duration: dur, iso: iso, completionHandler: nil)
                print("[ARFacadeCapture] custom exposure: \(CMTimeGetSeconds(dur))s ISO \(iso) EV \(exposureBiasEV)")
            } else if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            if device.isSubjectAreaChangeMonitoringEnabled {
                device.isSubjectAreaChangeMonitoringEnabled = false
            }

            cameraControlsLocked = true
            cameraControlsStatus = "camera.locked"
            print("[ARFacadeCapture] camera controls locked: exposure=\(device.exposureMode.rawValue) wb=\(device.whiteBalanceMode.rawValue) focus=\(device.focusMode.rawValue)")
        } catch {
            cameraControlsLocked = false
            cameraControlsStatus = "camera.lockFailed"
            print("[ARFacadeCapture] camera controls lock failed: \(error.localizedDescription)")
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

            // Rotazione angolare rispetto all'ultima cattura (per il trigger Auto).
            if let lastQ = lastCaptureOrientation {
                let curQ = simd_quatf(frame.camera.transform)
                let dotq = min(abs(simd_dot(lastQ.vector, curQ.vector)), 1)
                rotationFromLastCaptureDeg = 2 * acos(dotq) * 180 / .pi
            }
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

    /// Update live pose + roll a ogni frame ARKit. Throttle a ~10Hz per non
    /// stressare SwiftUI redraw (l'overlay si aggiorna comunque fluido).
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = CACurrentMediaTime()
        let throttleSec: TimeInterval = 0.10
        // Lock-free throttle: usiamo CACurrentMediaTime via static var-less hack
        // (la closure cattura currentTimestamp via property MainActor)
        let pose = frame.camera.transform
        let pitchDeg = frame.camera.eulerAngles.x * 180 / .pi
        let rollDeg = frame.camera.eulerAngles.z * 180 / .pi
        let yawRad = frame.camera.eulerAngles.y
        // FOV verticale dalla intrinsics: fy = intrinsics.columns.1.y, h = image height.
        // tan(FOV_v / 2) = h / (2 * fy)  →  FOV_v = 2 * atan(h / (2 * fy))
        let fy = frame.camera.intrinsics.columns.1.y
        let h = Float(frame.camera.imageResolution.height)
        let fovVDeg = 2 * atan(h / (2 * fy)) * 180 / .pi
        Task { @MainActor in
            if (now - self.lastPoseUpdateAt) >= throttleSec {
                self.lastPoseUpdateAt = now
                self.currentPose = pose
                self.currentPitchDeg = pitchDeg
                self.currentRollDeg = rollDeg
                self.currentYawRad = yawRad
                self.currentVerticalFOVDeg = fovVDeg
            }
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
