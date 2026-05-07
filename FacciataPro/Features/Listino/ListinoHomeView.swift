import SwiftUI
import SwiftData

struct ListinoHomeView: View {
    @Query private var prodotti: [Prodotto]
    @Query private var cicli: [CicloLavorazione]
    @Query private var voci: [VoceAccessoria]

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ProdottiListView()
                } label: {
                    ListinoCard(
                        icona: "cube.box.fill",
                        titolo: "Prodotti",
                        sottotitolo: "\(prodotti.count) materiali"
                    )
                }

                NavigationLink {
                    CicliListView()
                } label: {
                    ListinoCard(
                        icona: "arrow.triangle.2.circlepath",
                        titolo: "Cicli di lavorazione",
                        sottotitolo: "\(cicli.count) cicli configurati"
                    )
                }

                NavigationLink {
                    VociAccessorieView()
                } label: {
                    ListinoCard(
                        icona: "wrench.and.screwdriver",
                        titolo: "Voci accessorie",
                        sottotitolo: "\(voci.count) voci"
                    )
                }
            }
            .navigationTitle("Listino")
        }
    }
}

private struct ListinoCard: View {
    let icona: String
    let titolo: String
    let sottotitolo: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.tint.opacity(0.15))
                Image(systemName: icona).foregroundStyle(.tint)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(titolo).font(.headline)
                Text(sottotitolo).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ListinoHomeView()
        .modelContainer(for: AppSchema.allModels, inMemory: true)
}
