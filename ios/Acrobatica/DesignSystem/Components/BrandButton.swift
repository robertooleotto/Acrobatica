import SwiftUI

/// Bottone "brand" — variante primary (yellow su navy testo) e secondary (paper bordo navy).
struct BrandButton: View {
    enum Kind { case primary, secondary, ghost }

    let title: String
    var systemImage: String? = nil
    var kind: Kind = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let s = systemImage { Image(systemName: s) }
                Text(title)
            }
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundColor(foreground)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.l)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l))
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        switch kind {
        case .primary:   return Theme.navy
        case .secondary: return Theme.navy
        case .ghost:     return Theme.navy
        }
    }
    private var background: Color {
        switch kind {
        case .primary:   return Theme.yellow
        case .secondary: return Theme.paper
        case .ghost:     return .clear
        }
    }
    private var borderColor: Color {
        switch kind {
        case .primary:   return .clear
        case .secondary: return Theme.navy.opacity(0.16)
        case .ghost:     return Theme.navy.opacity(0.16)
        }
    }
    private var borderWidth: CGFloat {
        kind == .primary ? 0 : 1
    }
}

/// Bottone-pillola tondo per icone in chrome (es. AR top bar).
struct CircleIconButton: View {
    let systemImage: String
    var size: CGFloat = 44
    var foreground: Color = .white
    var background: AnyShapeStyle = AnyShapeStyle(.ultraThinMaterial)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(foreground)
                .frame(width: size, height: size)
                .background(background)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Bottone-pillola con icona+testo (es. "Stop").
struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var foreground: Color = Theme.yellow
    var background: Color = Theme.navy
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let s = systemImage { Image(systemName: s) }
                Text(title)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(background)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
