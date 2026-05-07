import SwiftUI
import UIKit

/// Wrapper di UIImagePickerController per scatto rapido o scelta da libreria.
/// Restituisce JPEG (compression 0.9) tramite onCapture.
struct CameraPicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = sourceType
        p.allowsEditing = false
        p.delegate = context.coordinator
        if sourceType == .camera {
            p.cameraCaptureMode = .photo
            // Griglia nativa di iOS è gestita dal sistema, niente overlay custom in MVP.
        }
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage,
               let jpeg = img.jpegData(compressionQuality: 0.9) {
                parent.onCapture(jpeg)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
