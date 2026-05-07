import SwiftUI

struct EsclusioneInfissiView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    @State private var apriExtra = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("3.4 · Esclusione infissi").font(.caption.monospaced()).foregroundStyle(.secondary)

                    Text("Disegna gli infissi da escludere")
                        .font(.title3.bold())

                    RoundedRectangle(cornerRadius: 12)
                        .fill(.tint.opacity(0.15))
                        .frame(height: 320)
                        .overlay(Text("[Canvas: rettangoli/poligoni a dito]")
                            .foregroundStyle(.secondary))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("DA IMPLEMENTARE").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("• Modalità: rettangolo / poligono libero")
                        Text("• Categoria: finestra / porta / portone / vetrina / altro")
                        Text("• Calcolo area con shoelace formula")
                        Text("• V2: tap-to-segment con VNGenerateForegroundInstanceMaskRequest")
                    }
                    .font(.caption)
                }
                .padding()
            }

            // Riepilogo live
            VStack(spacing: 8) {
                Divider()
                HStack {
                    VStack(alignment: .leading) {
                        Text("Lorda").font(.caption).foregroundStyle(.secondary)
                        Text("\(stato.superficieLordaMq, specifier: "%.1f") m²")
                            .font(.headline)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Esclusi").font(.caption).foregroundStyle(.secondary)
                        Text("-\(stato.areaEsclusiTotale, specifier: "%.1f") m²")
                            .font(.headline)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Netta").font(.caption).foregroundStyle(.secondary)
                        Text("\(stato.superficieNettaMq, specifier: "%.1f") m²")
                            .font(.headline)
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                HStack(spacing: 12) {
                    Button {
                        apriExtra = true
                    } label: {
                        Label("+ Extra (balconi…)", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onAvanti()
                    } label: {
                        Text("Avanti")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding([.horizontal, .bottom])
            }
            .background(.bar)
        }
        .navigationTitle("Infissi")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $apriExtra) {
            AggiungiExtraView(stato: stato)
        }
    }
}
