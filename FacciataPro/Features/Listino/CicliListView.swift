import SwiftUI
import SwiftData

struct CicliListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CicloLavorazione.nome) private var cicli: [CicloLavorazione]

    @State private var apriEdit = false
    @State private var cicloInModifica: CicloLavorazione?

    var body: some View {
        List {
            ForEach(cicli) { c in
                Button {
                    cicloInModifica = c
                    apriEdit = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.nome).font(.headline)
                            Spacer()
                            Text(c.categoria.label)
                                .font(.caption.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Text("\(c.steps.count) step · \(c.manodoperaEurMq, specifier: "%.0f") €/mq manodopera")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { idx in
                for i in idx { context.delete(cicli[i]) }
                try? context.save()
            }
        }
        .navigationTitle("Cicli")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    cicloInModifica = nil
                    apriEdit = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $apriEdit) {
            CicloEditView(ciclo: cicloInModifica)
        }
    }
}

#Preview {
    NavigationStack {
        CicliListView()
            .modelContainer(for: AppSchema.allModels, inMemory: true)
    }
}
