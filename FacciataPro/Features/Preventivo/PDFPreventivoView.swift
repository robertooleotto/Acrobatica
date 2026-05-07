import SwiftUI
import SwiftData
import PDFKit

struct PDFPreventivoView: View {
    @Bindable var preventivo: Preventivo
    let cantiere: Cantiere

    @Environment(\.modelContext) private var context
    @Query private var aziende: [Azienda]

    @State private var pdfData: Data?
    @State private var apriFirma = false
    @State private var fileURL: URL?

    var body: some View {
        VStack(spacing: 12) {
            if let data = pdfData {
                PDFKitView(data: data)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.tint.opacity(0.10))
                    .overlay(ProgressView("Generazione PDF…"))
            }

            HStack(spacing: 12) {
                if let url = fileURL {
                    ShareLink(item: url) {
                        Label("Condividi PDF", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }

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
        .navigationTitle(preventivo.numero.isEmpty ? "PDF preventivo" : preventivo.numero)
        .navigationBarTitleDisplayMode(.inline)
        .task { generaPDF() }
        .navigationDestination(isPresented: $apriFirma) {
            FirmaClienteView(preventivo: preventivo)
        }
    }

    private func generaPDF() {
        let azienda = aziende.first
        let data = PDFGenerator.genera(
            preventivo: preventivo,
            cantiere: cantiere,
            azienda: azienda
        )
        preventivo.pdfData = data
        try? context.save()
        pdfData = data
        salvaSuFile(data)
    }

    private func salvaSuFile(_ data: Data) {
        let safe = preventivo.numero.isEmpty ? "preventivo" : preventivo.numero
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe).pdf")
        try? data.write(to: url)
        fileURL = url
    }
}

private struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayDirection = .vertical
        v.usePageViewController(false)
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = PDFDocument(data: data)
    }
}
