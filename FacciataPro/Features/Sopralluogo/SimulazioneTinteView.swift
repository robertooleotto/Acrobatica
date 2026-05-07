import SwiftUI

struct SimulazioneTinteView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    @State private var coloreSelezionato: Color = .orange
    @State private var primaDopo: Bool = false

    private let palette: [Color] = [
        .init(red: 0.95, green: 0.85, blue: 0.70), // beige
        .init(red: 0.92, green: 0.80, blue: 0.60), // sabbia
        .init(red: 0.85, green: 0.65, blue: 0.50), // terracotta
        .init(red: 0.65, green: 0.45, blue: 0.35), // mattone
        .init(red: 0.95, green: 0.93, blue: 0.85), // panna
        .init(red: 0.80, green: 0.85, blue: 0.80), // verde salvia
        .init(red: 0.55, green: 0.70, blue: 0.75), // azzurro polvere
        .init(red: 0.85, green: 0.80, blue: 0.90)  // glicine
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 0)
                    .fill(coloreSelezionato.opacity(primaDopo ? 0.0 : 0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 0)
                            .fill(.tint.opacity(0.10))
                    )
                    .overlay(Text("[Anteprima facciata simulata]")
                        .foregroundStyle(.secondary))
                    .frame(height: 360)

                Button {
                    primaDopo.toggle()
                } label: {
                    Text(primaDopo ? "Mostra dopo" : "Mostra prima")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .padding()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(palette.indices, id: \.self) { i in
                        Circle()
                            .fill(palette[i])
                            .frame(width: 56, height: 56)
                            .overlay(
                                Circle().strokeBorder(coloreSelezionato == palette[i] ? .tint : .clear, lineWidth: 3)
                            )
                            .onTapGesture { coloreSelezionato = palette[i] }
                    }
                }
                .padding()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("DA IMPLEMENTARE").font(.caption.bold()).foregroundStyle(.secondary)
                Text("• Estrazione luminanza canale Y di YCbCr")
                Text("• Blending multiply per preservare ombre")
                Text("• CIBlendWithMask + custom CIFilter")
                Text("• Selezione zone con poligoni")
                Text("• Salva fino a 4 varianti (SimulazioneTinta)")
                Text("• Palette estesa: NCS, RAL, custom HEX")
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Spacer()

            Button {
                onAvanti()
            } label: {
                Text("Avanti")
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .navigationTitle("Simulazione tinte")
        .navigationBarTitleDisplayMode(.inline)
    }
}
