import Foundation

/// Stato di una sessione di scansione di una facciata.
enum FacadeSessionStatus: String, Codable {
    case capturing
    case uploading
    case processing
    case completed
    case failed
}

/// Aggregato della sessione lato iOS: lista foto scattate + stato + opzionale id backend.
struct FacadeCaptureSession: Codable {
    var id = UUID()
    var backendSessionId: String? = nil
    var name: String = ""
    var createdAt: Date = Date()
    var status: FacadeSessionStatus = .capturing
    var photos: [CapturedFacadePhoto] = []
}
