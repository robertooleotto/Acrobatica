import SwiftUI

struct CalibrazioneView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    @State private var misuraReale: String = ""
    @State private var lunghezzaSegmentoPx: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("3.3 · Calibrazione dimensionale")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text("Misura un riferimento noto")
                    .font(.title3.bold())

                Text("Trascina i due punti sulla foto su un oggetto di cui conosci la misura reale (es. larghezza porta = 90 cm) e inserisci il valore.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                RoundedRectangle(cornerRadius: 12)
                    .fill(.tint.opacity(0.15))
                    .frame(height: 280)
                    .overlay(Text("[Foto raddrizzata + segmento trascinabile]")
                        .foregroundStyle(.secondary))

                HStack {
                    Text("Lunghezza segmento")
                    Spacer()
                    Text("\(Int(lunghezzaSegmentoPx)) px")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Misura reale")
                    Spacer()
                    TextField("cm", text: $misuraReale)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }
                .padding()
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Text("DIMENSIONI STIMATE")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    HStack { Text("Larghezza"); Spacer(); Text("— m") }
                    HStack { Text("Altezza"); Spacer(); Text("— m") }
                    HStack { Text("Superficie lorda"); Spacer(); Text("— m²") }
                }
                .padding()
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("DA IMPLEMENTARE").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("• Selezione segmento a 2 punti su foto raddrizzata")
                    Text("• pixel_per_cm = lunghezza_px / misura_cm")
                    Text("• Calcolo larghezza/altezza dalla foto raddrizzata")
                    Text("• Doppio riferimento opzionale (uno per asse)")
                    Text("• Override manuale: input diretto larghezza × altezza")
                }
                .font(.caption)
            }
            .padding()
        }
        .navigationTitle("Calibrazione")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Avanti") { onAvanti() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
