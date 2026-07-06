import SwiftUI

/// Home: lista cantieri. Tap → DettaglioCantiereView. + Nuovo cantiere.
struct CantieriListView: View {
    @EnvironmentObject var app: AppState
    @State private var showNuovoSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.paper.ignoresSafeArea()

                if app.cantieri.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Cantieri")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNuovoSheet = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
            }
            .sheet(isPresented: $showNuovoSheet) {
                NuovoCantiereSheet { c in
                    app.cantieri.insert(c, at: 0)
                    showNuovoSheet = false
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(app.cantieri) { c in
                    NavigationLink(value: c.id) {
                        cantiereCard(c)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
        }
        .navigationDestination(for: UUID.self) { id in
            if let c = app.cantieri.first(where: { $0.id == id }) {
                DettaglioCantiereView(cantiere: c)
            }
        }
    }

    private func cantiereCard(_ c: Cantiere) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.navy)
                    .frame(width: 56, height: 56)
                Image(systemName: "building.2.fill")
                    .foregroundStyle(Theme.yellow)
                    .font(.system(size: 22))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(c.nome).font(Theme.Typo.title(17, .semibold)).foregroundStyle(Theme.navy)
                Text(c.cliente).font(Theme.Typo.body(13)).foregroundStyle(Theme.muted)
                Text("\(c.rilievi.count) facciat\(c.rilievi.count == 1 ? "a" : "e")")
                    .font(Theme.Typo.caption(11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(Theme.muted)
        }
        .padding(14)
        .background(Theme.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hair, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "building.2")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.muted)
            Text("Nessun cantiere").font(Theme.Typo.title())
                .foregroundStyle(Theme.navy)
            Text("Tocca + in alto per crearne uno")
                .font(Theme.Typo.body()).foregroundStyle(Theme.muted)
            Spacer()
            BrandButton(title: "Nuovo cantiere", systemImage: "plus", kind: .primary) {
                showNuovoSheet = true
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }
}

struct NuovoCantiereSheet: View {
    var clientePreset: String = ""
    let onCreate: (Cantiere) -> Void
    @State private var nome = ""
    @State private var cliente = ""
    @State private var indirizzo = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Cantiere") {
                    TextField("Nome", text: $nome)
                    TextField("Indirizzo", text: $indirizzo)
                }
                Section("Cliente") {
                    TextField("Nome cliente", text: $cliente)
                }
            }
            .navigationTitle("Nuovo cantiere")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if cliente.isEmpty { cliente = clientePreset } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea") {
                        onCreate(Cantiere(nome: nome.isEmpty ? "Cantiere senza nome" : nome,
                                          cliente: cliente,
                                          indirizzo: indirizzo))
                    }
                    .disabled(nome.isEmpty)
                }
            }
        }
    }
}
