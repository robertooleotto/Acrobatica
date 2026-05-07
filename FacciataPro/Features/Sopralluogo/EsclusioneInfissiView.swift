import SwiftUI
import UIKit

struct EsclusioneInfissiView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    @State private var puntiPoligono: [CGPoint] = []
    @State private var apriDettagliPoligono = false
    @State private var apriExtra = false

    private var fotoRaddrizzata: UIImage? {
        stato.fotoRaddrizzataData.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("3.4 · Esclusione infissi")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Text("Tocca per aggiungere i vertici dell'infisso")
                        .font(.title3.bold())

                    if let img = fotoRaddrizzata {
                        PoligonoCanvasView(
                            image: img,
                            puntiCorrenti: $puntiPoligono
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("Nessuna foto raddrizzata.").foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button(role: .destructive) {
                            puntiPoligono.removeAll()
                        } label: {
                            Label("Annulla", systemImage: "xmark")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(puntiPoligono.isEmpty)

                        Button {
                            apriDettagliPoligono = true
                        } label: {
                            Label("Chiudi & salva", systemImage: "checkmark")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(puntiPoligono.count < 3)
                    }

                    if !stato.elementiEsclusi.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ESCLUSIONI (\(stato.elementiEsclusi.count))")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ForEach(Array(stato.elementiEsclusi.enumerated()), id: \.offset) { idx, e in
                                HStack {
                                    Image(systemName: "rectangle.dashed")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(e.nome.isEmpty ? e.tipo.label : e.nome)
                                        Text(e.tipo.label)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(e.area, specifier: "%.2f") m²")
                                        .font(.callout.bold())
                                    Button {
                                        stato.elementiEsclusi.remove(at: idx)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding()
                        .background(.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }

            riepilogoBar
        }
        .navigationTitle("Infissi")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $apriDettagliPoligono) {
            DettagliPoligonoSheet(
                puntiNormalizzati: puntiPoligono,
                stato: stato,
                onSalva: { puntiPoligono.removeAll() }
            )
        }
        .sheet(isPresented: $apriExtra) {
            AggiungiExtraView(stato: stato)
        }
    }

    private var riepilogoBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Text("Lorda").font(.caption).foregroundStyle(.secondary)
                    Text("\(stato.superficieLordaMq, specifier: "%.1f") m²").font(.headline)
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("Esclusi").font(.caption).foregroundStyle(.secondary)
                    Text("-\(stato.areaEsclusiTotale, specifier: "%.1f") m²").font(.headline)
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
}

private struct PoligonoCanvasView: View {
    let image: UIImage
    @Binding var puntiCorrenti: [CGPoint]

    var body: some View {
        GeometryReader { proxy in
            let display = displayRect(in: proxy.size)
            let originX = (proxy.size.width - display.width) / 2
            let originY = (proxy.size.height - display.height) / 2

            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: display.width, height: display.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                let local = value.location
                                let nx = (local.x - originX) / max(1, display.width)
                                let ny = (local.y - originY) / max(1, display.height)
                                let clamped = CGPoint(
                                    x: min(1, max(0, nx)),
                                    y: min(1, max(0, ny))
                                )
                                puntiCorrenti.append(clamped)
                            }
                    )

                Path { p in
                    let pts = puntiCorrenti.map { norm2view($0, display: display, parent: proxy.size) }
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                    if pts.count >= 3 { p.closeSubpath() }
                }
                .stroke(Color.red, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))

                ForEach(Array(puntiCorrenti.enumerated()), id: \.offset) { _, p in
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .position(norm2view(p, display: display, parent: proxy.size))
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(image.size.width / max(1, image.size.height), contentMode: .fit)
    }

    private func displayRect(in size: CGSize) -> CGSize {
        let imgRatio = image.size.width / max(1, image.size.height)
        let containerRatio = size.width / max(1, size.height)
        if imgRatio > containerRatio {
            return CGSize(width: size.width, height: size.width / imgRatio)
        } else {
            return CGSize(width: size.height * imgRatio, height: size.height)
        }
    }

    private func norm2view(_ p: CGPoint, display: CGSize, parent: CGSize) -> CGPoint {
        let originX = (parent.width - display.width) / 2
        let originY = (parent.height - display.height) / 2
        return CGPoint(x: originX + p.x * display.width,
                       y: originY + p.y * display.height)
    }
}

private struct DettagliPoligonoSheet: View {
    let puntiNormalizzati: [CGPoint]
    @Bindable var stato: SopralluogoState
    let onSalva: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tipo: TipoElementoEscluso = .finestra
    @State private var nome: String = ""

    private var areaMq: Double {
        let areaNorm = Geometria.areaPoligono(puntiNormalizzati)
        return Geometria.areaNormalizzataInMq(
            areaNorm,
            widthPx: stato.fotoRaddrizzataWidthPx,
            heightPx: stato.fotoRaddrizzataHeightPx,
            pixelPerCm: stato.pixelPerCm
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo") {
                    Picker("Tipo", selection: $tipo) {
                        ForEach(TipoElementoEscluso.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    TextField("Nome (es. Finestra cucina)", text: $nome)
                }

                Section("Dimensione") {
                    LabeledContent("Vertici", value: "\(puntiNormalizzati.count)")
                    LabeledContent("Area", value: String(format: "%.2f m²", areaMq))
                }

                Section {
                    Button("Aggiungi esclusione") {
                        stato.elementiEsclusi.append((area: areaMq, tipo: tipo, nome: nome))
                        onSalva()
                        dismiss()
                    }
                    .disabled(areaMq <= 0)
                }
            }
            .navigationTitle("Dettagli infisso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }
}
