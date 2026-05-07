import SwiftUI

struct PDFPreventivoView: View {
    let cantiere: Cantiere

    @State private var apriFirma = false

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.tint.opacity(0.10))
                .overlay(
                    VStack {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                        Text("Anteprima PDF")
                            .font(.headline)
                        Text("[Da generare con PDFKit]")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                )

            VStack(alignment: .leading, spacing: 8) {
                Text("DA IMPLEMENTARE").font(.caption.bold()).foregroundStyle(.secondary)
                Text("• PDFKit: layout A4 con header logo + dati ditta")
                Text("• Foto prima/dopo")
                Text("• Tabella voci dal PricingResult")
                Text("• Subtotale, margine, IVA, totale")
                Text("• Footer: condizioni, validità, firma")
                Text("• Numerazione automatica preventivi")
            }
            .font(.caption)
            .padding()
            .background(.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                ShareLink(item: "Preventivo \(cantiere.nome)") {
                    Label("Condividi", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button {
                    apriFirma = true
                } label: {
                    Label("Firma cliente", systemImage: "signature")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .navigationTitle("PDF preventivo")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $apriFirma) {
            FirmaClienteView()
        }
    }
}
