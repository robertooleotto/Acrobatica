import SwiftUI
import SwiftData

struct ProdottiListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Prodotto.nomeCommerciale) private var prodotti: [Prodotto]

    @State private var ricerca = ""
    @State private var categoriaFiltro: CategoriaProdotto?
    @State private var apriEdit = false
    @State private var prodottoInModifica: Prodotto?

    private var filtrati: [Prodotto] {
        prodotti.filter {
            (categoriaFiltro == nil || $0.categoria == categoriaFiltro!)
            && (ricerca.isEmpty
                || $0.nomeCommerciale.localizedCaseInsensitiveContains(ricerca)
                || $0.brand.localizedCaseInsensitiveContains(ricerca))
        }
    }

    var body: some View {
        List {
            ForEach(filtrati) { p in
                Button {
                    prodottoInModifica = p
                    apriEdit = true
                } label: {
                    ProdottoRow(prodotto: p)
                }
                .buttonStyle(.plain)
            }
            .onDelete { idx in
                for i in idx { context.delete(filtrati[i]) }
                try? context.save()
            }
        }
        .navigationTitle("Prodotti")
        .searchable(text: $ricerca)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    prodottoInModifica = nil
                    apriEdit = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Tutte") { categoriaFiltro = nil }
                    Divider()
                    ForEach(CategoriaProdotto.allCases) { cat in
                        Button(cat.label) { categoriaFiltro = cat }
                    }
                } label: {
                    Label(categoriaFiltro?.label ?? "Categoria",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $apriEdit) {
            ProdottoEditView(prodotto: prodottoInModifica)
        }
    }
}

private struct ProdottoRow: View {
    let prodotto: Prodotto

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(prodotto.nomeCommerciale).font(.headline)
                Spacer()
                Text(prodotto.categoria.label)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15))
                    .clipShape(Capsule())
            }
            Text(prodotto.brand)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label("\(Int(prodotto.formatoVendita))\(prodotto.unita.simbolo)", systemImage: "shippingbox")
                Label("\(prodotto.prezzoUnitario, specifier: "%.2f") €/u", systemImage: "eurosign.circle")
                Label("\(Int(prodotto.resaMqPerUnita)) m²/u", systemImage: "square.grid.3x3")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        ProdottiListView()
            .modelContainer(for: AppSchema.allModels, inMemory: true)
    }
}
