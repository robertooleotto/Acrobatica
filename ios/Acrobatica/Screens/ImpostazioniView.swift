import SwiftUI

/// 6.4 Impostazioni / Profilo.
struct ImpostazioniView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var flow: AppFlow

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Profilo").font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.navy)
                        .padding(.top, 8)

                    profiloCard

                    sezione("Preventivi") {
                        NavigationLink { ListinoView() } label: {
                            rigaInfo("list.bullet.rectangle", "Listino prezzi", "\(app.listino.count) voci")
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Theme.hair)
                        rigaInfo("eurosign", "Tariffa oraria default", "€ \(Int(app.tariffaOrariaDefault))/h")
                        Divider().overlay(Theme.hair)
                        rigaInfo("percent", "IVA default", "\(Int(app.ivaDefault))%")
                        Divider().overlay(Theme.hair)
                        rigaInfo("calendar", "Validità default", "\(app.validitaDefault) giorni")
                        Divider().overlay(Theme.hair)
                        rigaInfo("tag", "Prefisso numerazione", app.prefissoPreventivo)
                    }

                    sezione("App") {
                        rigaInfo("icloud", "Dati e sincronizzazione", "OK")
                        Divider().overlay(Theme.hair)
                        rigaInfo("info.circle", "Informazioni", "")
                        Divider().overlay(Theme.hair)
                        rigaInfo("gearshape", "Versione", "2.4.0")
                    }

                    Button { flow.logout() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Esci")
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .background(Theme.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var profiloCard: some View {
        HStack(spacing: 12) {
            AvatarInitials(iniziali: iniziali(app.utenteNome), size: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.utenteNome).font(Theme.Typo.title(18)).foregroundStyle(Theme.navy)
                Text(app.utenteEmail).font(Theme.Typo.body(13)).foregroundStyle(Theme.muted)
                StatoChip(text: app.ruoloUtente == .senior ? "Senior" : "Operatore", tint: Theme.muted)
            }
            Spacer()
            Image(systemName: "pencil").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .acroCard(radius: 18, padding: 16)
    }

    private func sezione(_ titolo: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titolo.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.5)
                .foregroundStyle(Theme.muted).padding(.leading, 2)
            VStack(spacing: 0) { content() }.acroCard(radius: 16, padding: 14)
        }
    }

    private func rigaInfo(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.grayBg).frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.navy)
            }
            Text(label).font(Theme.Typo.body(14)).foregroundStyle(Theme.navy)
            Spacer()
            if !value.isEmpty {
                Text(value).font(Theme.Typo.mono(13)).foregroundStyle(Theme.muted)
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 11)
    }

    private func iniziali(_ nome: String) -> String {
        nome.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
