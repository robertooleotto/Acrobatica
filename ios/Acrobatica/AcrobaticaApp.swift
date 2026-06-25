import SwiftUI

@main
struct AcrobaticaApp: App {
    @StateObject private var app = AppState()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() { CrashReporter.install() }   // cattura crash → report al riavvio

    var body: some Scene {
        WindowGroup {
            EditorMesh3DView()   // TEMP-VERIFY-3D (avvio diretto per anteprima al simulatore)
                .environmentObject(app)
                .crashBanner()   // mostra il crash precedente, se c'è
                .onAppear { BackgroundUploader.shared.resumeOnLaunch() }
        }
    }
}

/// AppDelegate minimale: cattura gli eventi della background URLSession così
/// gli upload completati mentre l'app era sospesa/chiusa vengono finalizzati.
/// Gestisce anche gli orientamenti runtime: iPhone solo portrait, iPad libero
/// tranne dove una schermata blocca via `OrientationGate`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            BackgroundUploader.shared.backgroundCompletionHandler = completionHandler
            BackgroundUploader.shared.resumeOnLaunch()
        }
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? OrientationGate.mask : .portrait
    }
}

/// Orientamenti consentiti a runtime (vale solo su iPad: l'iPhone è sempre
/// portrait). La cattura AR blocca in portrait mentre è aperta: la sua UI
/// compensa DA SÉ la rotazione fisica del device (chrome contro-ruotato),
/// quindi l'interfaccia non deve ruotare sotto di lei.
enum OrientationGate {
    static var mask: UIInterfaceOrientationMask = .all

    @MainActor
    static func lock(_ m: UIInterfaceOrientationMask) {
        mask = m
        guard UIDevice.current.userInterfaceIdiom == .pad,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: m)) { _ in }
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
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

            #if DEBUG
            // Accesso diretto all'editor zone per provarlo nel Simulatore
            // (la cattura AR non gira in simulatore): carica l'ortofoto reale
            // servita in locale da `python3 -m http.server 8770`.
            DebugEditorTab()
                .tabItem { Label("Editor (debug)", systemImage: "pencil.and.outline") }
            #endif
        }
        .tint(Theme.navy)
    }
}

#if DEBUG
/// Tab di sviluppo: apre l'editor di marcatura zone con l'ortofoto reale
/// scaricata dal server locale (Mac). Solo per provare l'editor nel Simulatore.
struct DebugEditorTab: View {
    // L'ortofoto v22 servita da `http.server 8770` nella dir exports/facade_clean.
    // 10.0.2.2 NON serve: il Simulatore iOS condivide la rete del Mac → localhost.
    private let url = URL(string: "http://localhost:8770/tex_0_true60_v22.png")!
    @State private var id = UUID()
    var body: some View {
        MarcaturaFacciataCaricamentoView(
            url: url, ppm: 110, nomeDocumento: "Demo 6cdc",
            sessionId: nil, onChiudi: { id = UUID() }
        )
        .id(id)
    }
}
#endif
