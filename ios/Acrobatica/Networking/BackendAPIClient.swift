import Foundation
import CryptoKit
import UIKit

/// Client per il backend Python/FastAPI di Acrobatica.
///
/// Endpoint:
///   POST /facade-sessions
///   POST /facade-sessions/{id}/photos
///   POST /facade-sessions/{id}/process
///   GET  /facade-sessions/{id}/result
/// URL del backend: Railway di default, override via env BACKEND_URL per test locali.
enum AcroBackend {
    static let baseURL: URL = {
        if let s = ProcessInfo.processInfo.environment["BACKEND_URL"],
           let u = URL(string: s) { return u }
        return URL(string: "https://acrobatica-production.up.railway.app")!
    }()
}

actor BackendAPIClient {

    /// Backend deployato su Railway (servizio `Acrobatica`, project Railway omonimo).
    /// Storage e DB su Supabase. Override per test locale via env BACKEND_URL
    /// (es. SIMCTL_CHILD_BACKEND_URL=http://localhost:8000).
    var baseURL: URL = AcroBackend.baseURL

    static let shared = BackendAPIClient()

    /// Sessione URL dedicata: timeout generosi + attesa connettività + pochi
    /// socket per host (evita di saturare con decine di upload paralleli).
    private let urlSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 90
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = true
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    /// Cache della sessione corrente: `ensureSession()` la crea UNA sola volta
    /// anche se chiamata in parallelo (l'actor serializza), evitando sessioni doppie.
    private var cachedSessionId: String?

    private var assetCacheRoot: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Acrobatica", isDirectory: true)
            .appendingPathComponent("AssetCache", isDirectory: true)
    }

    func ensureSession() async throws -> String {
        if let s = cachedSessionId { return s }
        let s = try await createSession()
        cachedSessionId = s
        return s
    }

    /// Reset della sessione cache (es. inizio nuovo rilievo).
    func resetCachedSession() { cachedSessionId = nil }

    /// Upload con retry + backoff: ritenta sui timeout/errori di rete così un
    /// singolo intoppo non perde la foto (i frame sono già su disco).
    func uploadPhotoRetrying(sessionId: String, photo: CapturedFacadePhoto,
                             maxAttempts: Int = 4) async throws -> UploadResponse {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do { return try await uploadPhoto(sessionId: sessionId, photo: photo) }
            catch {
                lastError = error
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(Double(attempt) * 0.6 * 1_000_000_000))
                }
            }
        }
        throw lastError ?? APIError.httpError(0, "upload fallito")
    }

    // MARK: - Session

    struct CreateSessionResponse: Codable {
        let session_id: String
        let status: String
    }

    func createSession() async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("/facade-sessions"))
        req.httpMethod = "POST"
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        let decoded = try JSONDecoder().decode(CreateSessionResponse.self, from: data)
        return decoded.session_id
    }

    /// Chiude la cattura solo quando tutti gli upload sono terminati e la mette
    /// nella coda del Mac Object Capture.
    func finalizeAndRequestMesh(sessionId: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(
            "/facade-sessions/\(sessionId)/start-automatic"))
        request.httpMethod = "POST"
        let (requestData, requestResponse) = try await urlSession.data(for: request)
        try assertHTTPOK(requestResponse, data: requestData)
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
        let (data, resp) = try await urlSession.upload(for: req, from: body)
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

    // MARK: - Rettifica facciata 2D via 4-tap (NUOVO FLOW)

    struct RectifyPanoramaRequest: Codable {
        let src_quad: [[Double]]     // 4 punti TL, TR, BR, BL
        let source: String           // "stitched" | "composite"
        let output_max_dim: Int
    }

    struct RectifyPanoramaResult: Codable {
        let rectified_url: String
        let output_size: [Int]
        let homography_3x3: [[Double]]
    }

    func rectifyPanorama(sessionId: String,
                         srcQuad: [(Double, Double)],
                         source: String = "stitched",
                         outputMaxDim: Int = 2400) async throws -> RectifyPanoramaResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/rectify-panorama")
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = RectifyPanoramaRequest(
            src_quad: srcQuad.map { [$0.0, $0.1] },
            source: source, output_max_dim: outputMaxDim,
        )
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(RectifyPanoramaResult.self, from: data)
    }

    struct SetScaleRequest: Codable {
        let p1: [Double]; let p2: [Double]; let distance_m: Double
    }
    struct SetScaleResult: Codable {
        let meters_per_pixel: Double
        let facade_width_m: Double?
        let facade_height_m: Double?
    }
    func setScale(sessionId: String,
                  p1: (Double, Double), p2: (Double, Double),
                  distanceM: Double) async throws -> SetScaleResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/scale")
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = SetScaleRequest(p1: [p1.0, p1.1], p2: [p2.0, p2.1], distance_m: distanceM)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(SetScaleResult.self, from: data)
    }

    // MARK: - Marcatura zone (upload del documento dall'editor)

    struct ZoneMarkupResult: Codable {
        let session_id: String
        let zone_count: Int
        let area_m2_per_tipo: [String: Double]
        let lunghezza_m_per_tipo: [String: Double]
        let markup_url: String?
        let warnings: [String]
    }

    /// Invia il JSON di marcatura (già nello schema concordato, prodotto da
    /// `MarcaturaFacciata.jsonData()`). PUT idempotente: sostituisce la
    /// marcatura precedente della sessione.
    func uploadZoneMarkup(sessionId: String, jsonData: Data) async throws -> ZoneMarkupResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/zone-markup")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(ZoneMarkupResult.self, from: data)
    }

    /// Esito del salvataggio dei piani decisi nell'editor 3D.
    struct PlanesSaveResult: Codable {
        let session_id: String
        let count: Int
        let path: String
        let url: String
        let status: String
    }

    private struct PlanesDataResult: Decodable {
        let session_id: String
        let count: Int
        let url: String
        let generator_version: String?
    }

    private struct SavedPlanesDocument: Decodable {
        struct PianoBase: Decodable {
            let up: [Float]?
        }

        struct Plane: Decodable {
            let nome: String
            let tipo: String
            let punto: [Float]
            let normale: [Float]
            let corners: [[Float]]
            let triangoli: [Int]?
        }

        let planes: [Plane]
        let frame_edificio: BuildingFrame?
        let piano_base: PianoBase?
    }

    struct BuildingFrame: Codable {
        let origine: [Float]
        let right: [Float]
        let up: [Float]
        let normale: [Float]
        let source_plane_id: Int?
        let source: String
        let locked: Bool
    }

    struct SavedPlanesState {
        let planes: [DetectedPlane]
        let buildingFrame: BuildingFrame?
        let up: [Float]?
    }

    /// Recupera i piani revisionati gia salvati, senza rieseguire il detector.
    func downloadSavedPlanes(sessionId: String) async throws -> [DetectedPlane] {
        try await downloadSavedPlanesState(sessionId: sessionId).planes
    }

    /// Recupera piani e riferimento edificio persistente. Il frame viene applicato
    /// anche alla camera dell'editor, evitando che la selezione di un altro piano
    /// cambi implicitamente l'orientamento della facciata.
    func downloadSavedPlanesState(sessionId: String) async throws -> SavedPlanesState {
        let baseEndpoint = baseURL.appendingPathComponent(
            "/facade-sessions/\(sessionId)/planes-data")
        guard var components = URLComponents(
            url: baseEndpoint, resolvingAgainstBaseURL: false) else {
            throw APIError.httpError(0, "URL piani non valido")
        }
        components.queryItems = [
            URLQueryItem(name: "require_current", value: "true")
        ]
        guard let endpoint = components.url else {
            throw APIError.httpError(0, "URL piani non valido")
        }
        let (locationData, locationResponse) = try await urlSession.data(from: endpoint)
        try assertHTTPOK(locationResponse, data: locationData)
        let location = try JSONDecoder().decode(PlanesDataResult.self, from: locationData)
        guard let remote = URL(string: location.url) else {
            throw APIError.httpError(0, "URL piani non valido")
        }
        let (documentData, documentResponse) = try await urlSession.data(from: remote)
        try assertHTTPOK(documentResponse, data: documentData)
        let document = try JSONDecoder().decode(SavedPlanesDocument.self, from: documentData)
        let planes = document.planes.map { plane in
            DetectedPlane(
                nome: plane.nome,
                tipo: plane.tipo,
                punto: plane.punto,
                normale: plane.normale,
                corners: plane.corners,
                area_m2: 0,
                w: 0,
                h: 0,
                triangoli: plane.triangoli)
        }
        return SavedPlanesState(
            planes: planes,
            buildingFrame: document.frame_edificio,
            up: document.piano_base?.up)
    }

    /// Un piano rilevato automaticamente dal backend (Open3D: qualsiasi
    /// orientamento — verticali, falde oblique, poligoni/trapezi).
    struct DetectedPlane: Codable {
        let nome: String
        let tipo: String            // "facciata" | "spalla" | "falda" | "orizzontale"
        let punto: [Float]
        let normale: [Float]
        let corners: [[Float]]      // poligono di N vertici
        let area_m2: Float
        let w: Float
        let h: Float
        let triangoli: [Int]?       // triangoli mesh del piano (per la proiezione)
    }
    struct DetectPlanesResult: Codable {
        let session_id: String
        let up: [Float]
        let count: Int
        let mesh_kind: String?
        let planes: [DetectedPlane]
    }

    /// Rileva automaticamente i piani sulla mesh richiesta. `meshKind` evita che
    /// il backend sostituisca implicitamente raw e clean; `up` è la gravità nota.
    func detectPlanes(
        sessionId: String,
        up: [Float]? = nil,
        meshKind: String? = nil,
        persist: Bool = false
    ) async throws -> DetectPlanesResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/detect-planes")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [:]
        if let up { payload["up"] = up }
        if let meshKind { payload["mesh_kind"] = meshKind }
        if persist { payload["persist"] = true }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        // La mesh OC grezza puo superare un milione di triangoli: CGAL la
        // ripara, seziona e fonde nello stesso job prima di rispondere.
        req.timeoutInterval = 600
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(DetectPlanesResult.self, from: data)
    }

    /// Carica i piani decisi nell'editor 3D (passo 7) sul backend, che li
    /// conserva su storage in `out/planes.json`. La proiezione foto→piani li
    /// scaricherà da lì. `jsonData` = documento piani (schema acro.planes/v1).
    func uploadPlanes(sessionId: String, jsonData: Data) async throws -> PlanesSaveResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/planes-data")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(PlanesSaveResult.self, from: data)
    }

    struct ProjectionResult: Codable {
        struct Plane: Codable {
            let index: Int
            let nome: String?
            let file: String
            let width_m: Double
            let height_m: Double
            let area_m2: Double
            let coverage: Double
        }

        let session_id: String
        let status: String
        let count: Int
        let total_area_m2: Double
        let coverage: Double
        let main_obj: MeshFileInfo?
        let files: [MeshFileInfo]
        let state: String
        let progress: Double
        let message: String
        let error: String
        let projection_mode: String?
        let texture_encoding: String?
        let planes: [Plane]?
    }

    /// Avvia il bake cloud. Il timeout della singola richiesta è esteso perché
    /// selezione foto, raster e upload del bundle avvengono nello stesso job.
    func projectPlanes(sessionId: String) async throws -> ProjectionResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/project")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(ProjectionResult.self, from: data)
    }

    func projectionStatus(sessionId: String) async throws -> ProjectionResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/projection")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // Il bake usa CPU intensivamente. Una richiesta di stato deve fallire
        // presto e lasciare al chiamante la possibilita di riprovare.
        req.timeoutInterval = 15
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(ProjectionResult.self, from: data)
    }

    struct MetricOpening: Codable, Identifiable, Equatable {
        let id: String
        let plane_index: Int
        let type: String
        let polygon_uv: [[Double]]
        let confidence: Double
        let area_m2: Double
        var excluded: Bool
        let source: String
    }

    struct OpeningDetectionResult: Codable {
        let session_id: String
        let state: String
        let progress: Double
        let message: String
        let error: String
        let count: Int
        let openings: [MetricOpening]
        let gross_area_m2: Double
        let excluded_area_m2: Double
        let net_area_m2: Double
        let detector_model: String
        let segmenter_model: String
    }

    func detectOpenings(sessionId: String) async throws -> OpeningDetectionResult {
        let url = baseURL.appendingPathComponent(
            "/facade-sessions/\(sessionId)/detect-openings")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(OpeningDetectionResult.self, from: data)
    }

    func openingStatus(sessionId: String) async throws -> OpeningDetectionResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/openings")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(OpeningDetectionResult.self, from: data)
    }

    func reviewOpenings(
        sessionId: String,
        openings: [MetricOpening]
    ) async throws -> OpeningDetectionResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/openings")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["openings": openings])
        req.timeoutInterval = 30
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(OpeningDetectionResult.self, from: data)
    }

    /// Scarica le zone fuori-piano proposte dal backend (pre-marcatura
    /// automatica: balconi/aggetti oltre `sogliaM` dal piano facciata).
    /// Ritorna i Data del documento JSON nello schema di marcatura (lo
    /// decodifica l'editor con `MarcaturaFacciata.da(jsonData:)`).
    /// Prerequisito server: GET /planes già eseguito sulla sessione (409 se no).
    func fetchZoneProposals(sessionId: String, ppm: Double,
                            sogliaM: Double = 0.15) async throws -> Data {
        var comp = URLComponents(
            url: baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/zone-proposals"),
            resolvingAgainstBaseURL: false)!
        comp.queryItems = [
            URLQueryItem(name: "ppm", value: String(ppm)),
            URLQueryItem(name: "soglia_m", value: String(sogliaM)),
        ]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "GET"
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return data
    }

    // MARK: - Mesh 3D (Object Capture: download per l'editor 3D)

    struct MeshFileInfo: Codable, Identifiable {
        let name: String
        let url: String
        let size_bytes: Int
        let checksum: String?
        var id: String { name }
    }
    struct MeshInfoResult: Codable {
        let session_id: String
        let main_obj: MeshFileInfo?
        let files: [MeshFileInfo]
    }

    /// Info sulla mesh disponibile per la sessione (URL firmati). 404 se il Mac
    /// non l'ha ancora caricata via PUT /mesh.
    func fetchMeshInfo(sessionId: String, kind: String? = nil) async throws -> MeshInfoResult {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/mesh"),
            resolvingAgainstBaseURL: false)!
        if let kind { components.queryItems = [URLQueryItem(name: "kind", value: kind)] }
        guard let url = components.url else { throw APIError.httpError(0, "URL mesh non valido") }
        var req = URLRequest(url: url); req.httpMethod = "GET"
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(MeshInfoResult.self, from: data)
    }

    struct MeshUploadResult: Codable {
        let session_id: String
        let files: [MeshFileInfo]
    }

    struct ResetDerivedResult: Codable {
        let session_id: String
        let status: String
        let deleted_files: Int
    }

    /// Rimuove mesh clean e tutti gli output 3D derivati, conservando foto,
    /// pose e bundle Object Capture originale.
    func resetDerivedAssets(sessionId: String) async throws -> ResetDerivedResult {
        let url = baseURL.appendingPathComponent(
            "/facade-sessions/\(sessionId)/reset-derived")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(ResetDerivedResult.self, from: data)
    }

    /// Carica una mesh sul backend (es. quella RIPULITA dall'editor). `kind`:
    /// "clean" (default, dall'iPad) o "raw". Va su `sessions/<id>/out/mesh/<kind>/`
    /// senza sovrascrivere la grezza. Multipart PUT /mesh.
    func uploadMesh(sessionId: String, fileURL: URL, kind: String = "clean") async throws -> MeshUploadResult {
        let url = baseURL.appendingPathComponent("/facade-sessions/\(sessionId)/mesh")
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let crlf = "\r\n"
        var body = Data()
        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"kind\"\(crlf)\(crlf)")
        body.appendString("\(kind)\(crlf)")
        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\(crlf)")
        body.appendString("Content-Type: model/obj\(crlf)\(crlf)")
        body.append(fileData)
        body.appendString(crlf)
        body.appendString("--\(boundary)--\(crlf)")
        req.httpBody = body
        req.timeoutInterval = 120
        let (data, resp) = try await urlSession.data(for: req)
        try assertHTTPOK(resp, data: data)
        return try JSONDecoder().decode(MeshUploadResult.self, from: data)
    }

    /// Mantiene mesh e texture in Application Support. La firma usa checksum,
    /// nome e dimensione: un nuovo upload crea una revisione locale distinta.
    private func downloadCachedAssetBundle(
        sessionId: String,
        group: String,
        files: [MeshFileInfo]
    ) async throws -> [String: URL] {
        guard !files.isEmpty else { return [:] }
        let fileManager = FileManager.default
        var root = assetCacheRoot
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? root.setResourceValues(resourceValues)

        let namespace = root
            .appendingPathComponent(cacheSafeName(sessionId), isDirectory: true)
            .appendingPathComponent(cacheSafeName(group), isDirectory: true)
        try fileManager.createDirectory(at: namespace, withIntermediateDirectories: true)
        let fingerprint = assetFingerprint(files)
        let directory = namespace.appendingPathComponent(fingerprint, isDirectory: true)
        let marker = directory.appendingPathComponent(".complete")

        if fileManager.fileExists(atPath: marker.path),
           cachedFilesAreComplete(files, in: directory) {
            return cachedFileMap(files, in: directory)
        }

        let staging = namespace.appendingPathComponent(
            ".download-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            for info in files {
                guard let remote = URL(string: info.url) else {
                    throw APIError.httpError(0, "URL mesh non valido")
                }
                let (tmp, resp) = try await urlSession.download(from: remote)
                try assertHTTPOK(resp, data: Data())

                // Il backend espone nomi di file, non percorsi. lastPathComponent
                // evita comunque che un nome remoto esca dalla cartella dedicata.
                let name = URL(fileURLWithPath: info.name).lastPathComponent
                let destination = staging.appendingPathComponent(name)
                try fileManager.moveItem(at: tmp, to: destination)
                let size = (try? destination.resourceValues(
                    forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard info.size_bytes <= 0 || size == info.size_bytes else {
                    throw APIError.httpError(0, "Download incompleto: \(name)")
                }
                if let expected = info.checksum?.lowercased(), !expected.isEmpty {
                    let actual = try sha256(of: destination)
                    guard actual == expected else {
                        throw APIError.httpError(0, "Checksum non valido: \(name)")
                    }
                }
            }
            try Data(fingerprint.utf8).write(
                to: staging.appendingPathComponent(".complete"), options: .atomic)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: staging)
            } else {
                try fileManager.moveItem(at: staging, to: directory)
            }
            pruneCachedVersions(in: namespace, keeping: 2)
            return cachedFileMap(files, in: directory)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func downloadMeshFile(
        _ info: MeshFileInfo,
        sessionId: String,
        cacheGroup: String
    ) async throws -> URL {
        let bundle = try await downloadCachedAssetBundle(
            sessionId: sessionId, group: cacheGroup, files: [info])
        guard let local = bundle[info.name] else {
            throw APIError.httpError(0, "File mesh non disponibile in cache")
        }
        return local
    }

    /// Scarica nello stesso folder tutti i file che compongono una mesh OBJ.
    /// MTL e texture vengono risolti da SceneKit tramite i nomi relativi.
    func downloadMeshBundle(
        _ files: [MeshFileInfo],
        sessionId: String,
        cacheGroup: String
    ) async throws -> [String: URL] {
        try await downloadCachedAssetBundle(
            sessionId: sessionId, group: cacheGroup, files: files)
    }

    /// Bundle necessario a SceneKit; report JSON/TXT restano disponibili nel
    /// manifest ma non devono bloccare l'apertura del modello nell'app.
    func downloadProjectionBundle(
        sessionId: String,
        files: [MeshFileInfo]
    ) async throws -> [String: URL] {
        let renderExtensions: Set<String> = ["obj", "mtl", "png", "jpg", "jpeg"]
        let renderFiles = files.filter {
            renderExtensions.contains(
                URL(fileURLWithPath: $0.name).pathExtension.lowercased())
        }
        return try await downloadCachedAssetBundle(
            sessionId: sessionId, group: "projection", files: renderFiles)
    }

    /// Ultima revisione completa gia presente sul dispositivo, senza rete.
    func cachedAssetBundle(
        sessionId: String,
        cacheGroup: String
    ) -> [String: URL]? {
        let namespace = assetCacheRoot
            .appendingPathComponent(cacheSafeName(sessionId), isDirectory: true)
            .appendingPathComponent(cacheSafeName(cacheGroup), isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: namespace, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return nil }
        let versions = entries.filter { entry in
            guard (try? entry.resourceValues(forKeys: keys).isDirectory) == true else {
                return false
            }
            return FileManager.default.fileExists(
                atPath: entry.appendingPathComponent(".complete").path)
        }.sorted {
            let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }
        guard let latest = versions.first,
              let files = try? FileManager.default.contentsOfDirectory(
                at: latest, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]), !files.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: files.map {
            ($0.lastPathComponent, $0)
        })
    }

    private func cachedFilesAreComplete(
        _ files: [MeshFileInfo],
        in directory: URL
    ) -> Bool {
        files.allSatisfy { info in
            let name = URL(fileURLWithPath: info.name).lastPathComponent
            let local = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: local.path) else { return false }
            guard info.size_bytes > 0 else { return true }
            let size = try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size == info.size_bytes
        }
    }

    private func cachedFileMap(
        _ files: [MeshFileInfo],
        in directory: URL
    ) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: files.map { info in
            let name = URL(fileURLWithPath: info.name).lastPathComponent
            return (info.name, directory.appendingPathComponent(name))
        })
    }

    private func assetFingerprint(_ files: [MeshFileInfo]) -> String {
        let descriptor = files
            .map { "\($0.name):\($0.size_bytes):\($0.checksum ?? "-")" }
            .sorted()
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(descriptor.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func cacheSafeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(scalars)
    }

    private func pruneCachedVersions(in namespace: URL, keeping count: Int) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: namespace, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return }
        let versions = entries.filter {
            (try? $0.resourceValues(forKeys: keys).isDirectory) == true
        }.sorted {
            let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }
        for stale in versions.dropFirst(max(count, 1)) {
            try? FileManager.default.removeItem(at: stale)
        }
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

// MARK: - Background uploader (spostato qui: i file nuovi non sono nel pbxproj)

/// Stato di upload di una singola foto (condiviso con la UI).
enum UploadStatus: String, Codable { case pending, uploading, done, failed }

/// Uploader in BACKGROUND, robusto a standby / chiusura / crash.
///
/// Usa una `URLSession` con configurazione `.background`: i task continuano
/// quando l'app è in standby o terminata, e vengono **ripresi al riavvio**.
/// I body multipart sono scritti su file (requisito delle background session).
/// Una coda persistente su disco (`pending_uploads.json`) consente di
/// **ri-accodare** ciò che non era ancora partito dopo un crash.
@MainActor
final class BackgroundUploader: NSObject, ObservableObject {

    static let shared = BackgroundUploader()

    /// Stato per-foto (chiave = order_index) per la UI.
    @Published private(set) var statusByOrder: [Int: UploadStatus] = [:]
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    @Published private(set) var failed = 0

    /// Handler di sistema da chiamare quando finiscono gli eventi background
    /// (settato dall'AppDelegate in `handleEventsForBackgroundURLSession`).
    var backgroundCompletionHandler: (() -> Void)?

    private let baseURL = AcroBackend.baseURL
    private let maxRetry = 5
    private var responseData: [Int: Data] = [:]   // per taskIdentifier
    private var sessioniChiuse: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "closed_capture_sessions") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "closed_capture_sessions") }
    }
    private var sessioniInAccodamento: Set<String> = []

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: "com.acrobatica.upload.bg")
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.waitsForConnectivity = true
        c.httpMaximumConnectionsPerHost = 3
        c.timeoutIntervalForResource = 7 * 24 * 3600   // 7 giorni per completare
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    private struct Pending: Codable {
        let id: String
        let sessionId: String
        let photo: CapturedFacadePhoto
        var retry: Int
    }

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_uploads.json")
    }
    private var bodyDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("upload_bodies")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Store

    private func loadStore() -> [Pending] {
        guard let d = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: d)) ?? []
    }
    private func saveStore(_ items: [Pending]) {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: storeURL) }
    }
    private func removeFromStore(id: String) {
        var items = loadStore(); items.removeAll { $0.id == id }; saveStore(items)
    }

    // MARK: - API

    /// Accoda le foto per l'upload in background. Ritorna subito: il caricamento
    /// prosegue anche se l'utente lascia la schermata o mette l'app in standby.
    func enqueue(sessionId: String, photos: [CapturedFacadePhoto]) {
        var store = loadStore()
        let alreadyOrders = Set(store.map { $0.photo.orderIndex })
        for p in photos where !alreadyOrders.contains(p.orderIndex) {
            let pending = Pending(id: UUID().uuidString, sessionId: sessionId, photo: p, retry: 0)
            store.append(pending)
            statusByOrder[p.orderIndex] = .uploading
            startTask(for: pending)
        }
        saveStore(store)
        recomputeCounters()
    }

    /// Segna che non arriveranno altre foto per questa sessione. L'accodamento
    /// parte subito se la coda e vuota, oppure alla riuscita dell'ultimo upload.
    func finishCapture(sessionId: String) {
        var closed = sessioniChiuse
        closed.insert(sessionId)
        sessioniChiuse = closed
        provaFinalizzazione(sessionId: sessionId)
    }

    /// Da chiamare all'avvio dell'app: ricollega la background session (i task
    /// ancora vivi consegnano il completamento) e ri-accoda ciò che non era partito.
    func resumeOnLaunch() {
        let store = loadStore()
        for sessionId in sessioniChiuse
        where !store.contains(where: { $0.sessionId == sessionId }) {
            provaFinalizzazione(sessionId: sessionId)
        }
        guard !store.isEmpty else { return }
        for p in store { statusByOrder[p.photo.orderIndex] = .uploading }
        recomputeCounters()
        session.getAllTasks { tasks in
            let liveIds = Set(tasks.compactMap { $0.taskDescription })
            Task { @MainActor in
                for p in store where !liveIds.contains(p.id) {
                    self.startTask(for: p)   // non aveva un task vivo → ricrea
                }
            }
        }
    }

    /// Riprova una singola foto fallita.
    func retry(orderIndex: Int) {
        guard let p = loadStore().first(where: { $0.photo.orderIndex == orderIndex }) else { return }
        statusByOrder[orderIndex] = .uploading
        recomputeCounters()
        startTask(for: p)
    }

    /// Resetta lo stato visibile (a batch concluso) — non tocca i task in volo.
    func clearFinishedUI() {
        statusByOrder.removeAll(); total = 0; done = 0; failed = 0
    }

    var allFinished: Bool { total > 0 && done + failed >= total }

    // MARK: - Task creation

    private func startTask(for p: Pending) {
        guard let bodyURL = writeMultipartBody(for: p) else {
            markFailed(p, permanent: true); return
        }
        let boundary = "Boundary-\(p.id)"
        var req = URLRequest(url: baseURL.appendingPathComponent("/facade-sessions/\(p.sessionId)/photos"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: req, fromFile: bodyURL)
        task.taskDescription = p.id
        statusByOrder[p.photo.orderIndex] = .uploading
        task.resume()
    }

    private func writeMultipartBody(for p: Pending) -> URL? {
        let crlf = "\r\n"; let boundary = "Boundary-\(p.id)"
        guard let imageData = try? Data(contentsOf: p.photo.localImageURL) else { return nil }
        var meta: [String: Any] = [
            "order_index": p.photo.orderIndex,
            "timestamp": p.photo.timestampMs,
            "camera_transform": p.photo.cameraTransform,
            "camera_intrinsics": p.photo.cameraIntrinsics,
            "euler_angles": p.photo.eulerAnglesDeg,
            "tracking_state": p.photo.trackingState,
            "image_width": p.photo.imageWidth,
            "image_height": p.photo.imageHeight,
        ]
        if let n = p.photo.wallNormalWorld { meta["wall_normal_world"] = n }
        guard let metaData = try? JSONSerialization.data(withJSONObject: meta) else { return nil }

        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        add("--\(boundary)\(crlf)")
        add("Content-Disposition: form-data; name=\"metadata\"\(crlf)")
        add("Content-Type: application/json\(crlf)\(crlf)")
        body.append(metaData); add(crlf)
        add("--\(boundary)\(crlf)")
        add("Content-Disposition: form-data; name=\"image\"; filename=\"\(p.photo.localImageURL.lastPathComponent)\"\(crlf)")
        add("Content-Type: image/jpeg\(crlf)\(crlf)")
        body.append(imageData); add(crlf)
        add("--\(boundary)--\(crlf)")

        let url = bodyDir.appendingPathComponent("\(p.id).multipart")
        do { try body.write(to: url); return url } catch { return nil }
    }

    // MARK: - Completion handling

    private func finishSuccess(_ id: String) {
        let store = loadStore()
        let completed = store.first(where: { $0.id == id })
        if let p = store.first(where: { $0.id == id }) {
            statusByOrder[p.photo.orderIndex] = .done
        }
        try? FileManager.default.removeItem(at: bodyDir.appendingPathComponent("\(id).multipart"))
        removeFromStore(id: id)
        recomputeCounters()
        if let completed { provaFinalizzazione(sessionId: completed.sessionId) }
    }

    private func provaFinalizzazione(sessionId: String) {
        guard sessioniChiuse.contains(sessionId),
              !sessioniInAccodamento.contains(sessionId) else { return }
        let pendenti = loadStore().contains { $0.sessionId == sessionId }
        guard !pendenti, failed == 0 else { return }
        sessioniInAccodamento.insert(sessionId)
        Task {
            do {
                try await BackendAPIClient.shared.finalizeAndRequestMesh(
                    sessionId: sessionId)
                var closed = sessioniChiuse
                closed.remove(sessionId)
                sessioniChiuse = closed
            } catch {
                // La sessione resta persistita e verra ritentata al prossimo avvio.
            }
            sessioniInAccodamento.remove(sessionId)
        }
    }

    private func handleFailure(id: String) {
        var store = loadStore()
        guard let idx = store.firstIndex(where: { $0.id == id }) else { return }
        var p = store[idx]
        try? FileManager.default.removeItem(at: bodyDir.appendingPathComponent("\(id).multipart"))
        if p.retry < maxRetry {
            p.retry += 1
            store[idx] = p
            saveStore(store)
            // backoff semplice prima di ricreare il task
            let delay = Double(p.retry) * 2.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in self?.startTask(for: p) }
            }
        } else {
            statusByOrder[p.photo.orderIndex] = .failed
            store.remove(at: idx); saveStore(store)
            recomputeCounters()
        }
    }

    private func markFailed(_ p: Pending, permanent: Bool) {
        statusByOrder[p.photo.orderIndex] = .failed
        removeFromStore(id: p.id)
        recomputeCounters()
    }

    private func recomputeCounters() {
        total = statusByOrder.count
        done = statusByOrder.values.filter { $0 == .done }.count
        failed = statusByOrder.values.filter { $0 == .failed }.count
    }
}

// MARK: - URLSession delegate

extension BackgroundUploader: URLSessionDataDelegate {

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tid = dataTask.taskIdentifier
        Task { @MainActor in self.responseData[tid, default: Data()].append(data) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskDescription
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        let tid = task.taskIdentifier
        Task { @MainActor in
            self.responseData[tid] = nil
            guard let id = id else { return }
            if error == nil, (200..<300).contains(code) {
                self.finishSuccess(id)
            } else {
                self.handleFailure(id: id)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let h = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            h?()
        }
    }
}
