import SwiftUI

/// Firma del cliente sul preventivo via canvas (PencilKit semplificato).
/// Per ora: canvas a punti SwiftUI. Firma salvata in-memory (TODO: persistenza).
struct FirmaClienteView: View {
    @ObservedObject var preventivo: Preventivo
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [Stroke] = []
    @State private var current: Stroke?

    struct Stroke: Identifiable {
        let id = UUID()
        var points: [CGPoint] = []
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Firma del cliente").font(Theme.Typo.title(17))
                    .foregroundStyle(Theme.navy)
                Text("Firma confermando di aver letto e accettato il preventivo \(preventivo.numero).")
                    .font(Theme.Typo.body(13)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.white)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hair2, lineWidth: 1))
                Canvas { ctx, _ in
                    for s in strokes {
                        guard s.points.count > 1 else { continue }
                        var path = Path()
                        path.move(to: s.points[0])
                        for p in s.points.dropFirst() { path.addLine(to: p) }
                        ctx.stroke(path, with: .color(Theme.navy),
                                   style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    }
                    if let s = current, s.points.count > 1 {
                        var path = Path()
                        path.move(to: s.points[0])
                        for p in s.points.dropFirst() { path.addLine(to: p) }
                        ctx.stroke(path, with: .color(Theme.navy),
                                   style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if current == nil { current = Stroke() }
                            current?.points.append(v.location)
                        }
                        .onEnded { _ in
                            if let s = current { strokes.append(s) }
                            current = nil
                        }
                )
                if strokes.isEmpty && current == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "signature")
                            .font(.system(size: 36)).foregroundStyle(Theme.muted)
                        Text("Tocca e trascina per firmare")
                            .font(Theme.Typo.body()).foregroundStyle(Theme.muted)
                    }
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 280)

            HStack(spacing: 12) {
                BrandButton(title: "Cancella", systemImage: "trash", kind: .ghost) {
                    strokes.removeAll(); current = nil
                }
                BrandButton(title: "Conferma firma", systemImage: "checkmark", kind: .primary) {
                    // TODO: convertire Canvas in immagine + allegare al PDF
                    preventivo.stato = .accettato
                    dismiss()
                }
                .disabled(strokes.isEmpty)
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Firma")
        .navigationBarTitleDisplayMode(.inline)
    }
}
