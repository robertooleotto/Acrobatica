import SwiftUI
import SwiftData

struct RiepilogoFacciataView: View {
    let cantiere: Cantiere
    @Bindable var stato: SopralluogoState

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var nomeFacciata: String = "Facciata"

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
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.tint.opacity(0.15))
                        .frame(height: 120)
                        .overlay(Text("Originale").foregroundStyle(.secondary))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.tint.opacity(0.15))
                        .frame(height: 120)
                        .overlay(Text("Simulata").foregroundStyle(.secondary))
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

        try? context.save()
        dismiss()
    }
}
