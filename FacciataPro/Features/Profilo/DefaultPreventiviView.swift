import SwiftUI

struct DefaultPreventiviView: View {
    @AppStorage("default.iva") private var iva: Double = 22
    @AppStorage("default.validitaGiorni") private var validita: Int = 30
    @AppStorage("default.margine") private var margine: Double = 10
    @AppStorage("default.abbondamento") private var abbondamento: Double = 1.15
    @AppStorage("default.manodoperaEurMq") private var manodopera: Double = 18
    @AppStorage("default.numerazionePrefix") private var prefix: String = "PREV"

    var body: some View {
        Form {
            Section("Fiscale") {
                Stepper("IVA: \(iva, specifier: "%.0f")%", value: $iva, in: 0...30, step: 1)
            }

            Section("Preventivo") {
                Stepper("Validità: \(validita) gg", value: $validita, in: 7...365, step: 1)
                Stepper("Margine globale: \(margine, specifier: "%.0f")%",
                        value: $margine, in: 0...100, step: 1)
                TextField("Prefisso numerazione (es. PREV)", text: $prefix)
            }

            Section("Calcoli") {
                Stepper("Abbondamento: \(abbondamento, specifier: "%.2f")",
                        value: $abbondamento, in: 1.0...2.0, step: 0.05)
                Stepper("Manodopera standard: \(manodopera, specifier: "%.0f") €/mq",
                        value: $manodopera, in: 0...100, step: 1)
            }
        }
        .navigationTitle("Default preventivi")
        .navigationBarTitleDisplayMode(.inline)
    }
}
