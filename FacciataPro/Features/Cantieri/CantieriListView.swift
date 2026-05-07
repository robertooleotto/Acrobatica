import SwiftUI
import SwiftData

struct CantieriListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Cantiere.updatedAt, order: .reverse) private var cantieri: [Cantiere]

    @State private var ricerca = ""
    @State private var statoFiltro: StatoCantiere?
    @State private var mostraNuovo = false

    private var cantieriFiltrati: [Cantiere] {
        cantieri.filter { c in
            (statoFiltro == nil || c.stato == statoFiltro!) &&
            (ricerca.isEmpty
             || c.nome.localizedCaseInsensitiveContains(ricerca)
             || (c.cliente?.nome ?? "").localizedCaseInsensitiveContains(ricerca)
             || c.indirizzoCantiere.localizedCaseInsensitiveContains(ricerca))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if cantieri.isEmpty {
                    emptyState
                } else {
                    listView
                }
            }
            .navigationTitle("Cantieri")
            .searchable(text: $ricerca, prompt: "Cerca cliente, cantiere, indirizzo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        mostraNuovo = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Nuovo cantiere")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Tutti") { statoFiltro = nil }
                        Divider()
                        ForEach(StatoCantiere.allCases) { s in
                            Button(s.label) { statoFiltro = s }
                        }
                    } label: {
                        Label(statoFiltro?.label ?? "Filtri", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $mostraNuovo) {
                NuovoCantiereView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "house.lodge")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Nessun cantiere ancora")
                .font(.title3.bold())
            Text("Crea il primo cantiere per iniziare un sopralluogo.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                mostraNuovo = true
            } label: {
                Label("Nuovo cantiere", systemImage: "plus")
                    .padding(.horizontal)
                    .frame(minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var listView: some View {
        List(cantieriFiltrati) { c in
            NavigationLink {
                DettaglioCantiereView(cantiere: c)
            } label: {
                CantiereRow(cantiere: c)
            }
        }
        .listStyle(.plain)
    }
}

private struct CantiereRow: View {
    let cantiere: Cantiere

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.tint.opacity(0.15))
                Image(systemName: "house.fill")
                    .foregroundStyle(.tint)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(cantiere.nome)
                    .font(.headline)
                if let cliente = cantiere.cliente {
                    Text(cliente.nome)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !cantiere.indirizzoCantiere.isEmpty {
                    Text(cantiere.indirizzoCantiere)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(cantiere.stato.label)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.15))
                    .clipShape(Capsule())
                Text("\(cantiere.facciate.count) facciate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    CantieriListView()
        .modelContainer(for: AppSchema.allModels, inMemory: true)
}
