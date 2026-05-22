import Foundation
import simd

/// Una singola foto scattata + i metadati ARKit associati (pose + intrinsics).
struct CapturedFacadePhoto: Identifiable, Codable {
    let id: UUID
    let localImageURL: URL
    let thumbnailImage: Data?           // PNG/JPEG compresso per la UI strip
    let orderIndex: Int
    let timestampMs: Double             // unix epoch ms
    let imageWidth: Int
    let imageHeight: Int
    /// Camera→world, 16 floats column-major (come ARKit lo emette).
    let cameraTransform: [Float]
    /// 3x3 intrinsics, 9 floats column-major. K = [[fx,0,0],[0,fy,0],[cx,cy,1]].
    let cameraIntrinsics: [Float]
    /// pitch/yaw/roll dalla camera ARKit, gradi.
    let eulerAnglesDeg: [Float]
    /// "normal" | "notAvailable" | "limited.<reason>"
    let trackingState: String
    /// Normale del piano verticale ARKit sotto il reticle al momento dello scatto,
    /// in world coords. `nil` se non c'era un piano verticale stabile.
    /// Quando presente, il backend la usa per raddrizzare anche le orizzontali.
    let wallNormalWorld: [Float]?

    init(
        id: UUID = UUID(),
        localImageURL: URL,
        thumbnailImage: Data?,
        orderIndex: Int,
        timestampMs: Double,
        imageWidth: Int,
        imageHeight: Int,
        cameraTransform: simd_float4x4,
        cameraIntrinsics: simd_float3x3,
        eulerAnglesDeg: SIMD3<Float>,
        trackingState: String,
        wallNormalWorld: SIMD3<Float>? = nil
    ) {
        self.id = id
        self.localImageURL = localImageURL
        self.thumbnailImage = thumbnailImage
        self.orderIndex = orderIndex
        self.timestampMs = timestampMs
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.cameraTransform = CapturedFacadePhoto.flatten4(cameraTransform)
        self.cameraIntrinsics = CapturedFacadePhoto.flatten3(cameraIntrinsics)
        self.eulerAnglesDeg = [eulerAnglesDeg.x, eulerAnglesDeg.y, eulerAnglesDeg.z]
        self.trackingState = trackingState
        if let n = wallNormalWorld {
            self.wallNormalWorld = [n.x, n.y, n.z]
        } else {
            self.wallNormalWorld = nil
        }
    }

    private static func flatten4(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    private static func flatten3(_ m: simd_float3x3) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z,
            m.columns.1.x, m.columns.1.y, m.columns.1.z,
            m.columns.2.x, m.columns.2.y, m.columns.2.z,
        ]
    }
}
