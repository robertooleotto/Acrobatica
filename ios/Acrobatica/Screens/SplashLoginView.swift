import SwiftUI

// MARK: - 0.1 Splash

/// Schermata di avvio: logo su navy, auto-avanza al login dopo ~2.4s.
struct SplashView: View {
    var onFinish: () -> Void
    @State private var spin = false

    var body: some View {
        ZStack {
            Theme.navy.ignoresSafeArea()
            VStack(spacing: 20) {
                AcrobaticaLogoMark(size: 84, cornerRadius: 20)
                Text("Acrobatica")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.yellow)
                    .padding(.top, 12)
            }
            VStack {
                Spacer()
                Text("v2.4.0")
                    .font(Theme.Typo.mono(12))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 40)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onFinish)
        .task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            onFinish()
        }
    }
}

// MARK: - 0.2 Login

struct LoginView: View {
    @EnvironmentObject var app: AppState
    var onLogin: () -> Void

    @State private var email = "carlo@impresaedile.it"
    @State private var password = ""
    @State private var ruolo = "Operatore"
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    AcrobaticaLogoMark(size: 64, cornerRadius: 15)
                    Text("Acrobatica").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.navy)
                    Text("Rilievi di facciata dal suolo")
                        .font(Theme.Typo.body(14)).foregroundStyle(Theme.muted)
                }
                .padding(.top, 40)

                form.acroCard(radius: 18, padding: 18)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Theme.paper.ignoresSafeArea())
    }

    private var form: some View {
        VStack(spacing: 14) {
            DSField(label: "Email", text: $email, placeholder: "nome@azienda.it",
                    systemImage: "envelope", keyboard: .emailAddress)
            DSField(label: "Password", text: $password, placeholder: "••••••••",
                    systemImage: "lock", secure: true,
                    error: error)
                .onChange(of: password) { v in if !v.isEmpty { error = nil } }

            VStack(alignment: .leading, spacing: 6) {
                Text("RUOLO").font(.system(size: 10, weight: .semibold)).kerning(0.5)
                    .foregroundStyle(Theme.muted)
                RuoloSegmented(selection: $ruolo)
            }

            Button(action: submit) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22).fill(Theme.yellow)
                        .frame(maxWidth: .infinity, minHeight: 52)
                    if loading {
                        ProgressView().tint(Theme.navy)
                    } else {
                        Text("Accedi").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.navy)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .padding(.top, 4)

            Button { } label: {
                Text("Password dimenticata?")
                    .font(Theme.Typo.caption(13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func submit() {
        guard !password.isEmpty else { error = "Inserisci la password per continuare"; return }
        error = nil
        loading = true
        app.ruoloUtente = (ruolo == "Senior") ? .senior : .operatore
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            loading = false
            onLogin()
        }
    }
}

/// Segmented pill in stile design system (grayBg, selezionato bianco).
struct RuoloSegmented: View {
    @Binding var selection: String
    private let options = ["Operatore", "Senior"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { opt in
                let on = opt == selection
                Text(opt)
                    .font(Theme.Typo.caption(13, .semibold))
                    .foregroundStyle(on ? Theme.navy : Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 999)
                            .fill(on ? Theme.white : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 999)
                                .stroke(on ? Theme.hair2 : .clear, lineWidth: 1))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt }
            }
        }
        .padding(3)
        .background(Theme.grayBg, in: RoundedRectangle(cornerRadius: 999))
    }
}
