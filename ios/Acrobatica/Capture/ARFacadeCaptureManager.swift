import Foundation
import ARKit
import RealityKit
import UIKit
import simd

/// Gestisce la sessione ARKit (tracking continuo, pose della camera) e fornisce
/// l'API per scattare una foto ad alta risoluzione mantenendo il tracking.
///
/// Note:
/// - usiamo ARKit `captureHighResolutionFrame` (iOS 16+) per ottenere foto a piena
///   risoluzione del sensore con la pose sincronizzata; niente AVFoundation parallela.
/// - NO LiDAR richiesto: `ARWorldTrackingConfiguration` standard.
@MainActor
final class ARFacadeCaptureManager: NSObject, ObservableObject {

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published private(set) var trackingState: String = "limited.initializing"
    @Published private(set) var hasLidar: Bool = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    @Published private(set) var isBusy: Bool = false

    override init() {
        super.init()
        arView.session.delegate = self
        startSession()
    }

    func startSession() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical, .horizontal]
        config.environmentTexturing = .none
        config.worldAlignment = .gravity
        // Preferisci il video format ad alta risoluzione per cattura più dettagliata se disponibile.
        if let hires = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = hires
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func resetSession() {
        arView.session.pause()
        startSession()
    }

    /// Scatta una foto ad alta risoluzione e restituisce l'oggetto modello.
    /// Salva il JPEG nella documents directory dell'app.
    func captureHighResolutionPhoto(orderIndex: Int) async throws -> CapturedFacadePhoto {
        guard !isBusy else { throw CaptureError.busy }
        isBusy = true
        defer { isBusy = false }

        let frame: ARFrame = try await withCheckedThrowingContinuation { cont in
            arView.session.captureHighResolutionFrame { frame, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let frame = frame {
                    cont.resume(returning: frame)
                } else {
                    cont.resume(throwing: CaptureError.noFrame)
                }
            }
        }

        let pixelBuffer = frame.capturedImage
        let camera = frame.camera

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw CaptureError.imageConversionFailed
        }
        // ARKit captured image è in orientation landscape sensor. Per visualizzazione portrait taggo EXIF .right.
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        guard let jpeg = uiImage.jpegData(compressionQuality: 0.88) else {
            throw CaptureError.encodingFailed
        }

        let filename = "photo_\(UUID().uuidString.prefix(8)).jpg"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(filename)
        try jpeg.write(to: url)

        // thumb leggera (lato max 256)
        let thumb = uiImage.preparingThumbnail(of: CGSize(width: 256, height: 256))?.jpegData(compressionQuality: 0.7)

        let euler = SIMD3<Float>(
            camera.eulerAngles.x * 180 / .pi,
            camera.eulerAngles.y * 180 / .pi,
            camera.eulerAngles.z * 180 / .pi
        )

        return CapturedFacadePhoto(
            localImageURL: url,
            thumbnailImage: thumb,
            orderIndex: orderIndex,
            timestampMs: Date().timeIntervalSince1970 * 1000,
            imageWidth: CVPixelBufferGetWidth(pixelBuffer),
            imageHeight: CVPixelBufferGetHeight(pixelBuffer),
            cameraTransform: camera.transform,
            cameraIntrinsics: camera.intrinsics,
            eulerAnglesDeg: euler,
            trackingState: trackingStateString(camera.trackingState)
        )
    }

    enum CaptureError: LocalizedError {
        case busy, noFrame, imageConversionFailed, encodingFailed
        var errorDescription: String? {
            switch self {
            case .busy: "Cattura già in corso"
            case .noFrame: "Nessun frame disponibile da ARKit"
            case .imageConversionFailed: "Conversione immagine fallita"
            case .encodingFailed: "Encoding JPEG fallito"
            }
        }
    }

    private func trackingStateString(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal: "normal"
        case .notAvailable: "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: "limited.initializing"
            case .excessiveMotion: "limited.excessiveMotion"
            case .insufficientFeatures: "limited.insufficientFeatures"
            case .relocalizing: "limited.relocalizing"
            @unknown default: "limited.unknown"
            }
        @unknown default: "unknown"
        }
    }
}

extension ARFacadeCaptureManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor in
            self.trackingState = trackingStateString(camera.trackingState)
        }
    }
}
