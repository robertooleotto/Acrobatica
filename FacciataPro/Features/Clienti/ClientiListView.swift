import SwiftUI
import SwiftData

struct ClientiListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Cliente.nome) private var clienti: [Cliente]

    @State private var ricerca = ""
    @State private var apriEdit = false
    @State private var clienteInModifica: Cliente?

    private var filtrati: [Cliente] {
        if ricerca.isEmpty { return clienti }
        return clienti.filter { $0.nome.localizedCaseInsensitiveContains(ricerca) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if clienti.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.2")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                        Text("Nessun cliente").font(.title3.bold())
                        Text("Aggiungi il primo cliente per iniziare a tracciare i lavori.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    List {
                        ForEach(filtrati) { c in
                            Button {
                                clienteInModifica = c
                                apriEdit = true
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(c.nome).font(.headline)
                                    HStack(spacing: 8) {
                                        Text(c.tipo.label)
                                            .font(.caption.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.tint.opacity(0.15))
                                            .clipShape(Capsule())
                                        Text("\(c.cantieri.count) cantieri")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { idx in
                            for i in idx { context.delete(filtrati[i]) }
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle("Clienti")
            .searchable(text: $ricerca)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        clienteInModifica = nil
                        apriEdit = true
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .sheet(isPresented: $apriEdit) {
                ClienteEditView(cliente: clienteInModifica)
            }
        }
    }
}

#Preview {
    ClientiListView()
        .modelContainer(for: AppSchema.allModels, inMemory: true)
}
