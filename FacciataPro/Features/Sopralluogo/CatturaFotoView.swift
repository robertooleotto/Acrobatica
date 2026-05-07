import SwiftUI

struct CatturaFotoView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    var body: some View {
        PlaceholderView(
            screenCode: "3.1",
            title: "Cattura foto",
            phase: "Fase 3 — Sopralluogo",
            todo: [
                "Apertura camera fullscreen (AVFoundation)",
                "Overlay griglia + livello digitale (CMMotionManager)",
                "Suggerimenti dinamici basati sull'inclinazione",
                "Salvataggio in alta risoluzione (≥3000px lato lungo)",
                "Permessi NSCameraUsageDescription in Info.plist",
                "Fallback: PhotosPicker per selezionare da libreria"
            ]
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Avanti") { onAvanti() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
