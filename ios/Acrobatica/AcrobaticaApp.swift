import SwiftUI

@main
struct AcrobaticaApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(app)
        }
    }
}

/// Root: due tab (Cantieri / Preventivi). L'AR capture parte da DettaglioCantiere.
struct RootTabView: View {
    var body: some View {
        TabView {
            CantieriListView()
                .tabItem { Label("Cantieri", systemImage: "building.2.fill") }

            ListaPreventiviView()
                .tabItem { Label("Preventivi", systemImage: "doc.text.fill") }
        }
        .tint(Theme.navy)
    }
}
