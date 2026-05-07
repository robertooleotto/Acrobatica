import SwiftUI
import SwiftData
import UIKit

struct RiepilogoFacciataView: View {
    let cantiere: Cantiere
    @Bindable var stato: SopralluogoState

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var nomeFacciata: String = "Facciata"

    private var fotoOriginale: UIImage? {
        stato.fotoRaddrizzataData.flatMap { UIImage(data: $0) }
            ?? stato.fotoData.flatMap { UIImage(data: $0) }
    }

    private var fotoSimulata: UIImage? {
        guard let id = stato.varianteSelezionataId,
              let v = stato.variantiTinta.first(where: { $0.id == id }),
              let data = v.jpegPreview else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Form {
            Section("Dati facciata") {
                TextField("Nome facciata", text: $nomeFacciata)
                HStack { Text("Larghezza"); Spacer(); Text("\(stato.larghezzaM, specifier: "%.2f") m") }
                HStack { Text("Altezza"); Spacer(); Text("\(stato.altezzaM, specifier: "%.2f") m") }
                HStack { Text("Superficie lorda"); Spacer(); Text("\(stato.superficieLordaMq, specifier: "%.2f") m²") }
                HStack { Text("Esclusi"); Spacer(); Text("-\(stato.areaEsclusiTotale, specifier: "%.2f") m²") }
                HStack { Text("Extra"); Spacer(); Text("+\(stato.areaExtraTotale, specifier: "%.2f") m²") }
                HStack {
                    Text("Superficie netta").bold()
                    Spacer()
                    Text("\(stato.superficieNettaMq, specifier: "%.2f") m²")
                        .bold()
                        .foregroundStyle(.tint)
                }
            }

            Section("Foto") {
                HStack(spacing: 8) {
                    fotoCell(image: fotoOriginale, label: "Originale")
                    fotoCell(image: fotoSimulata, label: "Simulata")
                }
            }

            if !stato.variantiTinta.isEmpty {
                Section("Varianti tinta (\(stato.variantiTinta.count))") {
                    ForEach(stato.variantiTinta) { v in
                        HStack {
                            Circle()
                                .fill(Color(uiColor: ColorSimulator.uiColor(fromHex: v.coloreHex) ?? .gray))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.secondary.opacity(0.4)))
                            VStack(alignment: .leading) {
                                Text(v.nome)
                                Text(v.coloreHex)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if stato.varianteSelezionataId == v.id {
                                Text("Selezionata").font(.caption).foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    salvaFacciata()
                } label: {
                    Text("Salva e torna al cantiere")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("Riepilogo facciata")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func fotoCell(image: UIImage?, label: String) -> some View {
        VStack(spacing: 4) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.tint.opacity(0.15))
                    .frame(height: 120)
                    .overlay(Text(label).foregroundStyle(.secondary))
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func salvaFacciata() {
        let facciata = Facciata(
            nome: nomeFacciata,
            fotoOriginaleData: stato.fotoData,
            fotoRaddrizzataData: stato.fotoRaddrizzataData,
            pixelPerCm: stato.pixelPerCm,
            larghezzaM: stato.larghezzaM,
            altezzaM: stato.altezzaM,
            superficieLordaMq: stato.superficieLordaMq,
            superficieNettaMq: stato.superficieNettaMq,
            cantiere: cantiere
        )
        context.insert(facciata)

        for e in stato.elementiEsclusi {
            context.insert(ElementoEscluso(
                tipo: e.tipo, nome: e.nome, areaMq: e.area, facciata: facciata
            ))
        }
        for e in stato.elementiExtra {
            context.insert(ElementoExtra(
                tipo: e.tipo, nome: e.nome, areaMq: e.area, facciata: facciata
            ))
        }

        for v in stato.variantiTinta {
            let zona = ZonaSimulazione(
                poligono: PoligonoJSON(punti: []),
                coloreHex: v.coloreHex,
                cicloId: nil
            )
            let sim = SimulazioneTinta(
                nome: v.nome,
                zone: [zona],
                fotoSimulataData: v.jpegPreview,
                isSelected: stato.varianteSelezionataId == v.id,
                facciata: facciata
            )
            context.insert(sim)
        }

        try? context.save()
        dismiss()
    }
}
