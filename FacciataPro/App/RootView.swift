import SwiftUI
import SwiftData

struct RootView: View {
    @Query private var aziende: [Azienda]

    var body: some View {
        if aziende.first != nil {
            MainTabView()
        } else {
            OnboardingFlowView()
        }
    }
}

#Preview {
    RootView()
        .modelContainer(for: AppSchema.allModels, inMemory: true)
}
