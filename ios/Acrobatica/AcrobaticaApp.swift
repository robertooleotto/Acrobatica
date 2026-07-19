import SwiftUI

@main
struct AcrobaticaApp: App {
    @StateObject private var app = AppState()
    @StateObject private var flow = AppFlow()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() { CrashReporter.install() }   // cattura crash → report al riavvio

    var body: some Scene {
        WindowGroup {
            AppFlowView()
                .environmentObject(app)
                .environmentObject(flow)
                .crashBanner()   // mostra il crash precedente, se c'è
                .onAppear { BackgroundUploader.shared.resumeOnLaunch() }
        }
    }
}

/// Gestisce le fasi d'avvio: splash → login → app.
final class AppFlow: ObservableObject {
    enum Phase { case splash, login, main }
    @Published var phase: Phase

    init() {
        // Dev: SIMCTL_CHILD_SKIP_LOGIN=1 entra diretto nell'app.
        phase = ProcessInfo.processInfo.environment["SKIP_LOGIN"] == "1" ? .main : .splash
    }

    func login()  { withAnimation(.easeInOut) { phase = .main } }
    func logout() { withAnimation(.easeInOut) { phase = .login } }
}

/// Tab attiva condivisa (permette "Vedi tutti" e azioni rapide di cambiare tab).
enum AppTab: Hashable { case home, cantieri, preventivi, clienti, profilo }
final class TabRouter: ObservableObject { @Published var selected: AppTab = .home }

/// Root del flusso applicativo.
struct AppFlowView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var flow: AppFlow
    #if DEBUG
    @State private var debugComputoChiuso = false
    @State private var debugEditorChiuso = false
    #endif

    var body: some View {
        Group {
            #if DEBUG
            if let sessionId = ProcessInfo.processInfo.environment["DEBUG_COMPUTO_SESSION"],
               !sessionId.isEmpty, !debugComputoChiuso {
                ComputoMetricoView(sessionId: sessionId,
                                   onChiudi: {
                    flow.phase = .main
                    debugComputoChiuso = true
                })
            } else if let sessionId = ProcessInfo.processInfo.environment["DEBUG_EDITOR_SESSION"],
               !sessionId.isEmpty, !debugEditorChiuso {
                EditorMesh3DCaricamentoView(
                    sessionId: sessionId,
                    onChiudi: {
                        flow.phase = .main
                        debugEditorChiuso = true
                    })
            } else if let rawIndex = ProcessInfo.processInfo.environment["DEBUG_BUILDING_INDEX"],
                      let index = Int(rawIndex), app.cantieri.indices.contains(index) {
                NavigationStack {
                    DettaglioCantiereView(cantiere: app.cantieri[index])
                }
            } else {
                contenutoNormale
            }
            #else
            contenutoNormale
            #endif
        }
        .onAppear { app.caricaDemoSeInVuoto() }
    }

    @ViewBuilder private var contenutoNormale: some View {
        ZStack {
            switch flow.phase {
            case .splash: SplashView { flow.phase = .login }
            case .login:  LoginView(onLogin: { flow.login() })
            case .main:   RootTabView()
            }
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

/// Root: tab bar a 5 voci. L'AR capture parte da DettaglioCantiere.
struct RootTabView: View {
    @StateObject private var router = TabRouter()

    var body: some View {
        TabView(selection: $router.selected) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)

            CantieriListView()
                .tabItem { Label("Cantieri", systemImage: "building.2.fill") }
                .tag(AppTab.cantieri)

            ListaPreventiviView()
                .tabItem { Label("Preventivi", systemImage: "doc.text.fill") }
                .tag(AppTab.preventivi)

            ClientiListView()
                .tabItem { Label("Clienti", systemImage: "person.2.fill") }
                .tag(AppTab.clienti)

            ImpostazioniView()
                .tabItem { Label("Profilo", systemImage: "person.crop.circle") }
                .tag(AppTab.profilo)
        }
        .tint(Theme.navy)
        .environmentObject(router)
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
