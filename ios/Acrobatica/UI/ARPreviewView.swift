import SwiftUI
import RealityKit

/// Wrapper SwiftUI dell'ARView già gestita da `ARFacadeCaptureManager`.
struct ARPreviewView: UIViewRepresentable {
    let manager: ARFacadeCaptureManager

    func makeUIView(context: Context) -> ARView { manager.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
