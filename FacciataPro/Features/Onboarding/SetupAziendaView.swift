import SwiftUI
import SwiftData

struct SetupAziendaView: View {
    @Environment(\.modelContext) private var context

    @State private var ragioneSociale = ""
    @State private var partitaIva = ""
    @State private var codiceFiscale = ""
    @State private var indirizzo = ""
    @State private var cap = ""
    @State private var citta = ""
    @State private var provincia = ""
    @State private var telefono = ""
    @State private var email = ""
    @State private var pec = ""
    @State private var iban = ""
    @State private var ivaDefault: Double = 22

    private var canSave: Bool {
        !ragioneSociale.isEmpty && !partitaIva.isEmpty && !email.isEmpty
    }

    var body: some View {
        Form {
            Section("Dati ditta") {
                TextField("Ragione sociale *", text: $ragioneSociale)
                TextField("Partita IVA *", text: $partitaIva)
                    .keyboardType(.numberPad)
                TextField("Codice fiscale", text: $codiceFiscale)
                    .autocapitalization(.allCharacters)
            }

            Section("Sede") {
                TextField("Indirizzo", text: $indirizzo)
                TextField("CAP", text: $cap)
                    .keyboardType(.numberPad)
                TextField("Città", text: $citta)
                TextField("Provincia", text: $provincia)
                    .autocapitalization(.allCharacters)
            }

            Section("Contatti") {
                TextField("Telefono", text: $telefono)
                    .keyboardType(.phonePad)
                TextField("Email *", text: $email)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                TextField("PEC", text: $pec)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
            }

            Section("Fiscale") {
                TextField("IBAN", text: $iban)
                    .autocapitalization(.allCharacters)
                Stepper("IVA predefinita: \(ivaDefault, specifier: "%.0f")%",
                        value: $ivaDefault, in: 0...30, step: 1)
            }

            Section {
                Button {
                    salva()
                } label: {
                    Text("Salva e continua")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .navigationTitle("Setup ditta")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func salva() {
        let azienda = Azienda(
            ragioneSociale: ragioneSociale,
            partitaIva: partitaIva,
            codiceFiscale: codiceFiscale,
            indirizzo: indirizzo,
            cap: cap,
            citta: citta,
            provincia: provincia,
            telefono: telefono,
            email: email,
            pec: pec,
            iban: iban,
            ivaDefault: Decimal(ivaDefault)
        )
        context.insert(azienda)
        try? context.save()
    }
}

#Preview {
    NavigationStack {
        SetupAziendaView()
            .modelContainer(for: AppSchema.allModels, inMemory: true)
    }
}
