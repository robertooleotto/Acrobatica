import SwiftUI

struct RaddrizzamentoView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    var body: some View {
        PlaceholderView(
            screenCode: "3.2",
            title: "Raddrizzamento prospettico",
            phase: "Fase 3 — Sopralluogo",
            todo: [
                "Mostra foto originale con 4 punti angolari trascinabili (TL, TR, BR, BL)",
                "Toggle modalità: rettangolo (4 punti) / poligono libero",
                "Anteprima live della foto raddrizzata sotto",
                "Calcolo omografia: CIPerspectiveCorrection (Core Image)",
                "Salva matrice in stato.fotoRaddrizzataData + matrix",
                "Auto-detect opzionale (V2): VNDetectRectanglesRequest"
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
