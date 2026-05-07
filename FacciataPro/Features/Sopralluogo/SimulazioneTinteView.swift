import SwiftUI
import UIKit

struct SimulazioneTinteView: View {
    @Bindable var stato: SopralluogoState
    let onAvanti: () -> Void

    @State private var hexCorrente: String = "#F2D9B3"
    @State private var nomeCorrente: String = "Beige"
    @State private var primaDopo: Bool = false
    @State private var hexCustom: String = ""
    @State private var inElaborazione: Bool = false

    private static let maxVarianti = 4

    private var fotoBase: UIImage? {
        stato.fotoRaddrizzataData.flatMap { UIImage(data: $0) }
            ?? stato.fotoData.flatMap { UIImage(data: $0) }
    }

    private var fotoBaseData: Data? {
        stato.fotoRaddrizzataData ?? stato.fotoData
    }

    private var anteprima: UIImage? {
        guard let varianteId = stato.varianteSelezionataId,
              let v = stato.variantiTinta.first(where: { $0.id == varianteId }),
              let preview = v.jpegPreview else {
            return fotoBase
        }
        return primaDopo ? fotoBase : UIImage(data: preview)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                anteprimaArea

                paletteSection

                hexInputSection

                applicaButton

                if !stato.variantiTinta.isEmpty {
                    variantiSection
                }
            }
            .padding()
        }
        .navigationTitle("Simulazione tinte")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Avanti") { onAvanti() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var anteprimaArea: some View {
        ZStack(alignment: .topTrailing) {
            if let img = anteprima {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.tint.opacity(0.10))
                    .frame(height: 280)
                    .overlay(Text("Nessuna foto").foregroundStyle(.secondary))
            }

            if stato.varianteSelezionataId != nil {
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
        }
    }

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PALETTE")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(PalettiTinte.base) { t in
                        Button {
                            hexCorrente = t.hex
                            nomeCorrente = t.nome
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(Color(uiColor: ColorSimulator.uiColor(fromHex: t.hex) ?? .gray))
                                    .frame(width: 56, height: 56)
                                    .overlay(
                                        Circle().strokeBorder(
                                            hexCorrente == t.hex ? Color.accentColor : .clear,
                                            lineWidth: 3
                                        )
                                    )
                                Text(t.nome)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var hexInputSection: some View {
        HStack {
            Text("Custom HEX")
            TextField("#RRGGBB", text: $hexCustom)
                .autocapitalization(.allCharacters)
                .autocorrectionDisabled()
                .frame(maxWidth: 140)
            Button("Usa") {
                if ColorSimulator.uiColor(fromHex: hexCustom) != nil {
                    hexCorrente = hexCustom.hasPrefix("#") ? hexCustom : "#" + hexCustom
                    nomeCorrente = "Custom"
                }
            }
            .disabled(ColorSimulator.uiColor(fromHex: hexCustom) == nil)
        }
        .padding()
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var applicaButton: some View {
        Button {
            applicaTinta()
        } label: {
            HStack {
                if inElaborazione { ProgressView().tint(.white) }
                Label("Aggiungi variante", systemImage: "plus.circle.fill")
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(fotoBase == nil || inElaborazione || stato.variantiTinta.count >= Self.maxVarianti)

        if stato.variantiTinta.count >= Self.maxVarianti {
            Text("Massimo \(Self.maxVarianti) varianti.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var variantiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VARIANTI (\(stato.variantiTinta.count)/\(Self.maxVarianti))")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(stato.variantiTinta) { v in
                        VStack(spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                if let data = v.jpegPreview, let ui = UIImage(data: data) {
                                    Image(uiImage: ui)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 110, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(
                                                    stato.varianteSelezionataId == v.id ? Color.accentColor : .clear,
                                                    lineWidth: 3
                                                )
                                        )
                                }
                                Button {
                                    stato.variantiTinta.removeAll { $0.id == v.id }
                                    if stato.varianteSelezionataId == v.id {
                                        stato.varianteSelezionataId = stato.variantiTinta.first?.id
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .padding(4)
                            }
                            .onTapGesture {
                                stato.varianteSelezionataId = v.id
                            }
                            Text(v.nome)
                                .font(.caption2)
                            Text(v.coloreHex)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func applicaTinta() {
        guard let data = fotoBaseData else { return }
        inElaborazione = true
        let hex = hexCorrente
        let nome = nomeCorrente
        Task.detached(priority: .userInitiated) {
            let preview = ColorSimulator.simula(jpegData: data, hex: hex)
            await MainActor.run {
                inElaborazione = false
                guard let preview else { return }
                let v = VarianteTinta(nome: nome, coloreHex: hex, jpegPreview: preview)
                stato.variantiTinta.append(v)
                stato.varianteSelezionataId = v.id
                primaDopo = false
            }
        }
    }
}
