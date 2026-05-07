import SwiftUI
import SwiftData

struct ProfiloHomeView: View {
    @Query private var aziende: [Azienda]

    var body: some View {
        NavigationStack {
            List {
                if let a = aziende.first {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.ragioneSociale)
                                .font(.title3.bold())
                            Text("P.IVA \(a.partitaIva)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(a.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Configurazione") {
                    NavigationLink {
                        SetupAziendaView()
                    } label: {
                        Label("Dati ditta", systemImage: "building.2")
                    }
                    NavigationLink {
                        PersonalizzaPDFView()
                    } label: {
                        Label("Personalizza PDF", systemImage: "doc.text.image")
                    }
                    NavigationLink {
                        DefaultPreventiviView()
                    } label: {
                        Label("Default preventivi", systemImage: "slider.horizontal.3")
                    }
                }

                Section("Generale") {
                    Button {} label: {
                        Label("Backup e ripristino", systemImage: "externaldrive")
                    }
                    Button {} label: {
                        Label("Abbonamento", systemImage: "creditcard")
                    }
                    Button {} label: {
                        Label("Aiuto e supporto", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    Button(role: .destructive) {} label: {
                        Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Profilo")
        }
    }
}

#Preview {
    ProfiloHomeView()
        .modelContainer(for: AppSchema.allModels, inMemory: true)
}
