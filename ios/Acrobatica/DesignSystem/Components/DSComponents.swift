import SwiftUI

// MARK: - Formattazione valuta (it-IT, simbolo davanti)

extension Double {
    /// "€ 11.416,27"
    var eur: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "it_IT")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "€ " + (f.string(from: self as NSNumber) ?? "0,00")
    }
    /// "18" oppure "24,5" (senza zeri di troppo)
    var plain: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "it_IT")
        f.maximumFractionDigits = 2
        return f.string(from: self as NSNumber) ?? "0"
    }
}

// MARK: - Card (bianca, bordo hairline)

extension View {
    /// Superficie card standard: bianca, radius, bordo hairline navy 8%.
    func acroCard(radius: CGFloat = 16, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Theme.white, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.hair, lineWidth: 1))
    }
}

// MARK: - Tile icona (quadrato arrotondato navy con glifo giallo)

struct IconTile: View {
    let systemImage: String
    var size: CGFloat = 56
    var bg: Color = Theme.navy
    var fg: Color = Theme.yellow
    var glyph: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25).fill(bg)
            Image(systemName: systemImage)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(fg)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Avatar con iniziali

struct AvatarInitials: View {
    let iniziali: String
    var size: CGFloat = 48
    var navy: Bool = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(navy ? Theme.navy : Theme.grayBg)
            Text(iniziali)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(navy ? Theme.yellow : Theme.muted)
        }
        .frame(width: size, height: size)
    }
}

// (MetricCard è già definito in RisultatoPanoramaView.swift — riutilizzato qui.)

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var action: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Typo.title(17)).foregroundStyle(Theme.navy)
            if let count { Text("\(count)").font(Theme.Typo.caption()).foregroundStyle(Theme.muted) }
            Spacer()
            if let action, let onAction {
                Button(action: onAction) {
                    Text(action).font(Theme.Typo.caption(13, .semibold)).foregroundStyle(Theme.navy)
                }
            }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var subtitle: String = ""
    var cta: String? = nil
    var onCta: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(Theme.grayBg).frame(width: 72, height: 72)
                Image(systemName: systemImage)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Theme.muted)
            }
            Text(title).font(Theme.Typo.title(17)).foregroundStyle(Theme.navy).padding(.top, 6)
            if !subtitle.isEmpty {
                Text(subtitle).font(Theme.Typo.body(14)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 240)
            }
            if let cta, let onCta {
                BrandButton(title: cta, systemImage: "plus", kind: .primary, action: onCta)
                    .frame(maxWidth: 260).padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.vertical, 48)
    }
}

// MARK: - Campo di input (label micro + box grayBg)

struct DSField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var systemImage: String? = nil
    var secure: Bool = false
    var suffix: String? = nil
    var error: String? = nil
    var keyboard: UIKeyboardType = .default

    @State private var show = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold)).kerning(0.5)
                    .foregroundStyle(error != nil ? Theme.danger : Theme.muted)
            }
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15))
                        .foregroundStyle(Theme.muted).frame(width: 18)
                }
                Group {
                    if secure && !show {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(Theme.Typo.body(15))
                .foregroundStyle(Theme.navy)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

                if let suffix {
                    Text(suffix).font(Theme.Typo.mono(13)).foregroundStyle(Theme.muted)
                }
                if secure {
                    Button { show.toggle() } label: {
                        Image(systemName: show ? "eye.slash" : "eye")
                            .font(.system(size: 15))
                            .foregroundStyle(show ? Theme.navy : Theme.muted)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(Theme.grayBg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(error != nil ? Theme.danger : .clear, lineWidth: 1))

            if let error {
                Text(error).font(Theme.Typo.caption(12)).foregroundStyle(Theme.danger)
            }
        }
    }
}

// MARK: - Marchio

struct AcrobaticaLogoMark: View {
    var size: CGFloat
    var cornerRadius: CGFloat? = nil

    var body: some View {
        Image("AcrobaticaLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(
                cornerRadius: cornerRadius ?? size * 0.22,
                style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Wordmark (icona app + nome)

struct Wordmark: View {
    var size: CGFloat = 40
    var word: CGFloat = 22
    var onNavy: Bool = false

    var body: some View {
        HStack(spacing: size * 0.3) {
            AcrobaticaLogoMark(size: size)
            Text("Acrobatica")
                .font(.system(size: word, weight: .bold))
                .foregroundStyle(onNavy ? .white : Theme.navy)
        }
    }
}

// MARK: - Tint di stato

extension Rilievo.Stato {
    var tint: Color {
        switch self {
        case .bozza:      return Theme.muted
        case .inCattura:  return Theme.warning
        case .elaborato:  return Theme.success
        case .completato: return Theme.success
        }
    }
}

extension Preventivo.Stato {
    var tint: Color {
        switch self {
        case .bozza:     return Theme.muted
        case .inviato:   return Theme.warning
        case .accettato: return Theme.success
        case .rifiutato: return Theme.danger
        case .scaduto:   return Theme.muted
        }
    }
    var etichetta: String { rawValue.capitalized }
}
