import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            CantieriListView()
                .tabItem { Label("Cantieri", systemImage: "house.lodge") }

            ListinoHomeView()
                .tabItem { Label("Listino", systemImage: "list.bullet.rectangle") }

            ClientiListView()
                .tabItem { Label("Clienti", systemImage: "person.2") }

            ProfiloHomeView()
                .tabItem { Label("Profilo", systemImage: "person.crop.circle") }
        }
    }
}

#Preview {
    MainTabView()
        .modelContainer(for: AppSchema.allModels, inMemory: true)
}
