import SwiftUI
import UIKit

struct FirmaClienteView: View {
    @Bindable var preventivo: Preventivo

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var strokes: [[CGPoint]] = []
    @State private var nomeFirmatario: String = ""
    @State private var accettato = false
    @State private var canvasSize: CGSize = .zero

    private var puoConfermare: Bool {
        accettato && !nomeFirmatario.isEmpty && !strokes.isEmpty
    }

    var body: some View {
        Form {
            Section("Firma") {
                FirmaCanvas(strokes: $strokes, canvasSize: $canvasSize)
                    .frame(height: 200)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Pulisci firma") { strokes.removeAll() }
                    .foregroundStyle(.secondary)
                    .disabled(strokes.isEmpty)
            }

            Section("Firmatario") {
                TextField("Nome e cognome", text: $nomeFirmatario)
                    .onAppear { nomeFirmatario = preventivo.nomeFirmatario }
            }

            Section {
                Toggle("Accetto le condizioni del preventivo", isOn: $accettato)
            }

            Section {
                Button {
                    salva()
                } label: {
                    Text("Conferma firma")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!puoConfermare)
            }
        }
        .navigationTitle("Firma cliente")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func salva() {
        guard let data = renderFirma() else { return }
        preventivo.firmaClienteData = data
        preventivo.firmaData = Date()
        preventivo.nomeFirmatario = nomeFirmatario
        preventivo.updatedAt = Date()
        if cantiereStato == .bozza { aggiornaStato(.inviato) }
        try? context.save()
        dismiss()
    }

    private var cantiereStato: StatoCantiere {
        preventivo.cantiere?.stato ?? .bozza
    }

    private func aggiornaStato(_ s: StatoCantiere) {
        preventivo.cantiere?.stato = s
        preventivo.cantiere?.updatedAt = Date()
    }

    private func renderFirma() -> Data? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.pngData { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            UIColor.black.setStroke()
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                let path = UIBezierPath()
                path.lineWidth = 2
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: first)
                for p in stroke.dropFirst() { path.addLine(to: p) }
                path.stroke()
            }
        }
    }
}

private struct FirmaCanvas: View {
    @Binding var strokes: [[CGPoint]]
    @Binding var canvasSize: CGSize

    @State private var stroke: [CGPoint] = []

    var body: some View {
        GeometryReader { proxy in
            Canvas { ctx, size in
                ctx.stroke(
                    Path { p in
                        for s in strokes {
                            guard let first = s.first else { continue }
                            p.move(to: first)
                            for pt in s.dropFirst() { p.addLine(to: pt) }
                        }
                        if let first = stroke.first {
                            p.move(to: first)
                            for pt in stroke.dropFirst() { p.addLine(to: pt) }
                        }
                    },
                    with: .color(.black),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        stroke.append(value.location)
                    }
                    .onEnded { _ in
                        if !stroke.isEmpty {
                            strokes.append(stroke)
                            stroke = []
                        }
                    }
            )
            .onAppear { canvasSize = proxy.size }
            .onChange(of: proxy.size) { _, newValue in canvasSize = newValue }
        }
    }
}
