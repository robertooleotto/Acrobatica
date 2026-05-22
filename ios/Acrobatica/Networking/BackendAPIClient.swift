import Foundation
import UIKit

/// Client per il backend Python/FastAPI di Acrobatica.
///
/// Endpoint:
///   POST /facade-sessions
///   POST /facade-sessions/{id}/photos
///   POST /facade-sessions/{id}/process
///   GET  /facade-sessions/{id}/result
actor BackendAPIClient {

    /// Backend deployato su Railway (servizio `Acrobatica`, project Railway omonimo).
    /// Storage e DB su Supabase. Niente Mac acceso necessario.
    var baseURL: URL = URL(string: "https://acrobatica-production.up.railway.app")!

    static let shared = BackendAPIClient()

    // MARK: - Session

    struct CreateSessionResponse: Codable {
        let session_id: String
        let status: String
    }

    func createSession() async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("/facade-sessions"))
        req.httpMethod = "POST"
        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(resp, data: data)
        let decoded = try JSONDecoder().decode(CreateSessionResponse.self, from: data)
        return decoded.session_id
    }

    // MARK: - Upload

    struct UploadResponse: Codable {
        let session_id: String
        let order_index: Int
        let photos_count: Int
    }

    func uploadPhoto(sessionId: String, photo: CapturedFacadePhoto) async throws -> UploadResponse {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/photos")
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = try makeMultipartBody(boundary: boundary, photo: photo)
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    private func makeMultipartBody(boundary: String, photo: CapturedFacadePhoto) throws -> Data {
        var body = Data()
        let crlf = "\r\n"

        // Metadata JSON come stringa "metadata" field.
        var metadata: [String: Any] = [
            "order_index": photo.orderIndex,
            "timestamp": photo.timestampMs,
            "camera_transform": photo.cameraTransform,
            "camera_intrinsics": photo.cameraIntrinsics,
            "euler_angles": photo.eulerAnglesDeg,
            "tracking_state": photo.trackingState,
            "image_width": photo.imageWidth,
            "image_height": photo.imageHeight
        ]
        if let n = photo.wallNormalWorld {
            metadata["wall_normal_world"] = n
        }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"metadata\"\(crlf)")
        body.appendString("Content-Type: application/json\(crlf)\(crlf)")
        body.append(metadataData)
        body.appendString(crlf)

        // File JPEG.
        let imageData = try Data(contentsOf: photo.localImageURL)
        let filename = photo.localImageURL.lastPathComponent
        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\(crlf)")
        body.appendString("Content-Type: image/jpeg\(crlf)\(crlf)")
        body.append(imageData)
        body.appendString(crlf)

        body.appendString("--\(boundary)--\(crlf)")
        return body
    }

    // MARK: - Process

    struct ProcessResult: Codable {
        let stitched_url: String?
        let rectified_url: String?
        let gross_area_pixels: Double
        let excluded_area_pixels: Double
        let net_area_pixels: Double
        let gross_area_m2: Double?
        let net_area_m2: Double?
        let warnings: [String]
    }

    func processSession(sessionId: String) async throws -> ProcessResult {
        return try await processSession(sessionId: sessionId, facadeQuadPixels: nil)
    }

    /// `facadeQuadPixels`: 4 punti pixel nell'immagine stitched, in ordine TL, TR, BR, BL,
    /// che il backend userà per la rettifica prospettica `rectify_from_quad`.
    func processSession(sessionId: String, facadeQuadPixels: [[Double]]?) async throws -> ProcessResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/process")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let quad = facadeQuadPixels { body["facade_quad_pixels"] = quad }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(ProcessResult.self, from: data)
    }

    // MARK: - Triangulate

    struct CornerTap: Codable {
        let photo_order_index: Int
        let pixel: [Double]  // [x, y] in pixel ARKit raw
    }

    struct TriangulateRequest: Codable {
        /// 4 angoli (TL, TR, BR, BL), ognuno con >= 2 tap su foto diverse.
        let corners: [[CornerTap]]
    }

    struct TriangulateResult: Codable {
        let corners_3d: [[Double]]
        let width_m: Double
        let height_m: Double
        let area_m2: Double
        let warnings: [String]
    }

    func triangulate(sessionId: String, request: TriangulateRequest) async throws -> TriangulateResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/triangulate")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(TriangulateResult.self, from: data)
    }

    // MARK: - Wall plane + Orthorectify (Step 4: ortografia metrica della facciata)

    struct WallPlane: Codable {
        let point:  [Double]
        let normal: [Double]
        let right:  [Double]
        let up:     [Double]
        let u_min: Double; let u_max: Double
        let v_min: Double; let v_max: Double
    }

    func computeWallPlane(sessionId: String, request: TriangulateRequest) async throws -> WallPlane {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/wall-plane")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(WallPlane.self, from: data)
    }

    struct OrthoPhotoResult: Codable, Identifiable {
        let order_index: Int
        let ortho_url: String
        let pre_rotated_cw: Bool
        let output_size: [Int]
        let pixels_per_meter: Double
        var id: Int { order_index }
    }

    struct OrthoSessionResult: Codable {
        let wall_plane: WallPlane
        let photos: [OrthoPhotoResult]
        let composite_url: String?
        let warnings: [String]
    }

    func orthorectify(sessionId: String, pixelsPerMeter: Double = 200) async throws -> OrthoSessionResult {
        var comp = URLComponents(url: baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/orthorectify"),
                                 resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "pixels_per_meter", value: String(pixelsPerMeter))]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "POST"
        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(OrthoSessionResult.self, from: data)
    }

    // MARK: - Keystone (Step 2: foto raddrizzate singolarmente)

    struct KeystonePhotoResult: Codable, Identifiable {
        let order_index: Int
        let original_url: String
        let rectified_url: String
        let pitch_deg: Double
        let roll_deg: Double
        let yaw_deg: Double
        let input_size: [Int]
        let output_size: [Int]
        var id: Int { order_index }
    }

    struct KeystoneSessionResult: Codable {
        let photos: [KeystonePhotoResult]
        let warnings: [String]
    }

    func keystoneSession(sessionId: String) async throws -> KeystoneSessionResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/keystone")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(KeystoneSessionResult.self, from: data)
    }

    // MARK: -

    enum APIError: LocalizedError {
        case httpError(Int, String)
        var errorDescription: String? {
            switch self {
            case .httpError(let code, let body): "HTTP \(code): \(body.prefix(200))"
            }
        }
    }

    private func assertHTTPOK(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if !(200..<300 ~= http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(http.statusCode, body)
        }
    }
}

private extension Data {
    mutating func appendString(_ s: String) {
        if let d = s.data(using: .utf8) { append(d) }
    }
}
