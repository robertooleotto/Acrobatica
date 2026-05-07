import SwiftUI

enum OnboardingStep: Hashable {
    case setup
}

struct OnboardingFlowView: View {
    @State private var path: [OnboardingStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(onContinue: { path.append(.setup) })
                .navigationDestination(for: OnboardingStep.self) { step in
                    switch step {
                    case .setup:
                        SetupAziendaView()
                    }
                }
        }
    }
}

#Preview {
    OnboardingFlowView()
        .modelContainer(for: AppSchema.allModels, inMemory: true)
}
