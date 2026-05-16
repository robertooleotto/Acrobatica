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

    /// In dev: IP del Mac sulla LAN (per iPhone reale) o localhost (simulatore).
    /// In produzione: il VPS pubblico.
    var baseURL: URL = URL(string: "http://192.168.1.21:8000")!

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
        let metadata: [String: Any] = [
            "order_index": photo.orderIndex,
            "timestamp": photo.timestampMs,
            "camera_transform": photo.cameraTransform,
            "camera_intrinsics": photo.cameraIntrinsics,
            "euler_angles": photo.eulerAnglesDeg,
            "tracking_state": photo.trackingState,
            "image_width": photo.imageWidth,
            "image_height": photo.imageHeight
        ]
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
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/process")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(ProcessResult.self, from: data)
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
