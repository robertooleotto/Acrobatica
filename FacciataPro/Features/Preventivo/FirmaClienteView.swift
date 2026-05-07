import SwiftUI

struct FirmaClienteView: View {
    @State private var nomeFirmatario = ""
    @State private var accettato = false

    var body: some View {
        Form {
            Section("Firma") {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 1)
                    .frame(height: 200)
                    .overlay(Text("[Canvas firma]").foregroundStyle(.secondary))
                Button("Pulisci firma") { /* TODO */ }
                    .foregroundStyle(.secondary)
            }

            Section("Firmatario") {
                TextField("Nome e cognome", text: $nomeFirmatario)
            }

            Section {
                Toggle("Accetto le condizioni del preventivo", isOn: $accettato)
            }

            Section {
                Button {
                    /* TODO: salva firma */
                } label: {
                    Text("Conferma firma")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!accettato || nomeFirmatario.isEmpty)
            }
        }
        .navigationTitle("Firma cliente")
        .navigationBarTitleDisplayMode(.inline)
    }
}
