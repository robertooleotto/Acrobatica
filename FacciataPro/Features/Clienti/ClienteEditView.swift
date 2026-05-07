import SwiftUI
import SwiftData

struct ClienteEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let cliente: Cliente?

    @State private var tipo: TipoCliente = .privato
    @State private var nome = ""
    @State private var partitaIva = ""
    @State private var codiceFiscale = ""
    @State private var telefono = ""
    @State private var email = ""
    @State private var indirizzo = ""
    @State private var cap = ""
    @State private var citta = ""
    @State private var provincia = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipologia") {
                    Picker("Tipo", selection: $tipo) {
                        ForEach(TipoCliente.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                }

                Section("Anagrafica") {
                    TextField(tipo == .privato ? "Nome e cognome *" : "Ragione sociale *",
                              text: $nome)
                    TextField("Partita IVA", text: $partitaIva)
                        .keyboardType(.numberPad)
                    TextField("Codice fiscale", text: $codiceFiscale)
                        .autocapitalization(.allCharacters)
                }

                Section("Contatti") {
                    TextField("Telefono", text: $telefono)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }

                Section("Indirizzo") {
                    TextField("Indirizzo", text: $indirizzo)
                    HStack {
                        TextField("CAP", text: $cap)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 80)
                        TextField("Città", text: $citta)
                        TextField("Pr.", text: $provincia)
                            .autocapitalization(.allCharacters)
                            .frame(maxWidth: 60)
                    }
                }

                Section("Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Button(cliente == nil ? "Crea cliente" : "Salva modifiche") {
                        salva()
                    }
                    .disabled(nome.isEmpty)
                }
            }
            .navigationTitle(cliente == nil ? "Nuovo cliente" : "Modifica cliente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .onAppear { popolaSeEdit() }
        }
    }

    private func popolaSeEdit() {
        guard let c = cliente else { return }
        tipo = c.tipo
        nome = c.nome
        partitaIva = c.partitaIva
        codiceFiscale = c.codiceFiscale
        telefono = c.telefono
        email = c.email
        indirizzo = c.indirizzo
        cap = c.cap
        citta = c.citta
        provincia = c.provincia
        note = c.note
    }

    private func salva() {
        if let c = cliente {
            c.tipo = tipo
            c.nome = nome
            c.partitaIva = partitaIva
            c.codiceFiscale = codiceFiscale
            c.telefono = telefono
            c.email = email
            c.indirizzo = indirizzo
            c.cap = cap
            c.citta = citta
            c.provincia = provincia
            c.note = note
            c.updatedAt = Date()
        } else {
            context.insert(Cliente(
                tipo: tipo, nome: nome,
                partitaIva: partitaIva, codiceFiscale: codiceFiscale,
                telefono: telefono, email: email,
                indirizzo: indirizzo, cap: cap, citta: citta, provincia: provincia,
                note: note
            ))
        }
        try? context.save()
        dismiss()
    }
}
