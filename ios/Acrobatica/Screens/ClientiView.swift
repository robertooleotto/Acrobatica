import SwiftUI

// MARK: - 6.1 Clienti / Lista

struct ClientiListView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var showNuovo = false

    private var filtrati: [Cliente] {
        guard !query.isEmpty else { return app.clienti }
        return app.clienti.filter { $0.nome.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom) {
                        Text("Clienti").font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.navy)
                        Spacer()
                        Button { showNuovo = true } label: {
                            Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Theme.navy)
                        }
                    }
                    .padding(.top, 8)

                    searchBar

                    if filtrati.isEmpty {
                        EmptyStateView(systemImage: "person.2",
                                       title: query.isEmpty ? "Nessun cliente" : "Nessun risultato",
                                       subtitle: query.isEmpty
                                           ? "Aggiungi il primo cliente per collegarlo a cantieri e preventivi"
                                           : "Nessun cliente corrisponde a \"\(query)\"",
                                       cta: query.isEmpty ? "Nuovo cliente" : nil,
                                       onCta: { showNuovo = true })
                    } else {
                        ForEach(filtrati) { c in
                            NavigationLink { ClienteDettaglioView(cliente: c) } label: { row(c) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .background(Theme.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showNuovo) { NuovoClienteSheet() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.muted)
            TextField("Cerca cliente", text: $query)
                .font(Theme.Typo.body(15)).foregroundStyle(Theme.navy)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Theme.grayBg, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ c: Cliente) -> some View {
        HStack(spacing: 12) {
            AvatarInitials(iniziali: c.iniziali)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.nome).font(Theme.Typo.body(15, .semibold)).foregroundStyle(Theme.navy)
                Text("\(c.citta) · \(app.cantieri(di: c).count) cantier\(app.cantieri(di: c).count == 1 ? "e" : "i")")
                    .font(Theme.Typo.body(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .acroCard(radius: 14, padding: 12)
    }
}

// MARK: - 6.2 Cliente / Dettaglio

struct ClienteDettaglioView: View {
    @ObservedObject var cliente: Cliente
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showNuovoCantiere = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                navBar
                testataCard
                SectionHeader(title: "Cantieri", count: app.cantieri(di: cliente).count)
                let miei = app.cantieri(di: cliente)
                if miei.isEmpty {
                    Text("Nessun cantiere per questo cliente.")
                        .font(Theme.Typo.body(13)).foregroundStyle(Theme.muted)
                }
                ForEach(miei) { c in
                    NavigationLink { DettaglioCantiereView(cantiere: c) } label: { cantiereRow(c) }
                        .buttonStyle(.plain)
                }
                SectionHeader(title: "Preventivi", count: app.preventivi(di: cliente).count)
                let prev = app.preventivi(di: cliente)
                if prev.isEmpty {
                    Text("Nessun preventivo per questo cliente.")
                        .font(Theme.Typo.body(13)).foregroundStyle(Theme.muted)
                }
                ForEach(prev) { p in
                    NavigationLink { AnteprimaPreventivoView(preventivo: p) } label: { prevRow(p) }
                        .buttonStyle(.plain)
                }
                BrandButton(title: "Nuovo cantiere per questo cliente", systemImage: "plus", kind: .secondary) {
                    showNuovoCantiere = true
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showNuovoCantiere) {
            NuovoCantiereSheet(clientePreset: cliente.nome) { c in
                app.cantieri.insert(c, at: 0)
                showNuovoCantiere = false
            }
        }
    }

    private var navBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.navy)
            }
            Spacer()
            Text("Cliente").font(Theme.Typo.title(17)).foregroundStyle(Theme.navy)
            Spacer()
            Image(systemName: "pencil").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.navy)
        }
        .padding(.vertical, 4)
    }

    private var testataCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AvatarInitials(iniziali: cliente.iniziali, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(cliente.nome).font(Theme.Typo.title(18)).foregroundStyle(Theme.navy)
                    Text("P.IVA \(cliente.partitaIva)").font(Theme.Typo.body(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            Divider().overlay(Theme.hair).padding(.top, 12).padding(.bottom, 3)
            contatto(icon: "phone.fill", value: cliente.telefono, url: telURL)
            Divider().overlay(Theme.hair)
            contatto(icon: "envelope.fill", value: cliente.email, url: URL(string: "mailto:\(cliente.email)"))
            Divider().overlay(Theme.hair)
            contatto(icon: "mappin.and.ellipse", value: cliente.indirizzo, url: mapURL)
        }
        .acroCard(radius: 18, padding: 16)
    }

    private func contatto(icon: String, value: String, url: URL?) -> some View {
        Button { if let url { openURL(url) } } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.grayBg).frame(width: 34, height: 34)
                    Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.navy)
                }
                Text(value.isEmpty ? "—" : value).font(Theme.Typo.body(14)).foregroundStyle(Theme.navy)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    private var telURL: URL? {
        let digits = cliente.telefono.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel://\(digits)")
    }
    private var mapURL: URL? {
        let q = cliente.indirizzo.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return q.isEmpty ? nil : URL(string: "http://maps.apple.com/?q=\(q)")
    }

    private func cantiereRow(_ c: Cantiere) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "building.2.fill", size: 44, glyph: 19)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.nome).font(Theme.Typo.body(15, .semibold)).foregroundStyle(Theme.navy)
                Text("\(c.rilievi.count) facciat\(c.rilievi.count == 1 ? "a" : "e")")
                    .font(Theme.Typo.body(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .acroCard(radius: 14, padding: 12)
    }

    private func prevRow(_ p: Preventivo) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "doc.text.fill", size: 44, bg: Theme.grayBg, fg: Theme.navy.opacity(0.5), glyph: 18)
            Text(p.numero).font(Theme.Typo.mono(13)).foregroundStyle(Theme.navy)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(p.totale.eur).font(Theme.Typo.mono(14)).foregroundStyle(Theme.navy)
                StatoChip(text: p.stato.etichetta, tint: p.stato.tint)
            }
        }
        .acroCard(radius: 14, padding: 12)
    }
}

// MARK: - Sheet nuovo cliente

struct NuovoClienteSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var nome = ""
    @State private var telefono = ""
    @State private var partitaIva = ""
    @State private var email = ""
    @State private var indirizzo = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSField(label: "Nome / Ragione sociale", text: $nome, placeholder: "Es. Rossi Costruzioni S.r.l.")
                    HStack(spacing: 10) {
                        DSField(label: "Telefono", text: $telefono, placeholder: "+39…", systemImage: "phone", keyboard: .phonePad)
                        DSField(label: "P.IVA", text: $partitaIva, placeholder: "IT…")
                    }
                    DSField(label: "Email", text: $email, placeholder: "nome@azienda.it", systemImage: "envelope", keyboard: .emailAddress)
                    DSField(label: "Indirizzo", text: $indirizzo, placeholder: "Via, numero, città", systemImage: "mappin.and.ellipse")
                }
                .padding(16)
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Nuovo cliente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        app.clienti.insert(Cliente(nome: nome, telefono: telefono,
                                                   email: email, indirizzo: indirizzo,
                                                   partitaIva: partitaIva.isEmpty ? "—" : partitaIva),
                                           at: 0)
                        dismiss()
                    }.disabled(nome.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}
