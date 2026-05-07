import SwiftUI

struct WelcomeSlide: Identifiable {
    let id = UUID()
    let icona: String
    let titolo: String
    let sottotitolo: String
}

struct WelcomeView: View {
    let onContinue: () -> Void

    private let slides: [WelcomeSlide] = [
        .init(icona: "camera.viewfinder",
              titolo: "Misura la facciata in un attimo",
              sottotitolo: "Scatta una foto e usa un riferimento noto. FacciataPro calcola larghezza, altezza e superficie."),
        .init(icona: "paintpalette.fill",
              titolo: "Simula le tinte sul posto",
              sottotitolo: "Mostra al cliente l'effetto prima/dopo direttamente sulla foto della sua facciata."),
        .init(icona: "doc.text.fill",
              titolo: "Preventivo professionale in PDF",
              sottotitolo: "Calcolo automatico di materiali, manodopera, accessorie. Firma digitale del cliente.")
    ]

    @State private var pagina = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $pagina) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { idx, slide in
                    VStack(spacing: 24) {
                        Image(systemName: slide.icona)
                            .font(.system(size: 80))
                            .foregroundStyle(.tint)
                        Text(slide.titolo)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(slide.sottotitolo)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding()
                    .tag(idx)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                onContinue()
            } label: {
                Text(pagina == slides.count - 1 ? "Inizia" : "Avanti")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .navigationTitle("Benvenuto")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        WelcomeView(onContinue: {})
    }
}
