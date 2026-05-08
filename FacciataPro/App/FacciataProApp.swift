import SwiftUI
import SwiftData

@main
struct FacciataProApp: App {
    let container: ModelContainer

    init() {
        self.container = AppSchema.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
                .task { @MainActor in
                    SeedData.seedIfNeeded(container.mainContext)
                }
        }
        .modelContainer(container)
    }
}
