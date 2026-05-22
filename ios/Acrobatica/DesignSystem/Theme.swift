import SwiftUI

/// Design tokens per Acrobatica. Palette + tipografia + spacing.
/// Riferimento: handoff "FacciataPro" — adattato col nome app "Acrobatica".
enum Theme {

    // ─── Palette ───────────────────────────────────────────────
    static let yellow  = Color(hex: 0xF5DC0F)
    static let navy    = Color(hex: 0x0F1E48)
    static let ink     = Color(hex: 0x1A1A1A)
    static let paper   = Color(hex: 0xF7F6F2)
    static let grayBg  = Color(hex: 0xEEECE6)
    static let white   = Color.white

    // Hairlines / muted
    static let hair    = Color(hex: 0x0F1E48, alpha: 0.08)
    static let hair2   = Color(hex: 0x0F1E48, alpha: 0.16)
    static let muted   = Color(hex: 0x0F1E48, alpha: 0.55)

    // Feedback
    static let success = Color(hex: 0x1FA463)
    static let warning = Color(hex: 0xF5A524)
    static let danger  = Color(hex: 0xD9342B)

    // ─── Tipografia ────────────────────────────────────────────
    enum Typo {
        static func display(_ size: CGFloat = 34, _ weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func title(_ size: CGFloat = 22, _ weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func body(_ size: CGFloat = 15, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func caption(_ size: CGFloat = 12, _ weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func mono(_ size: CGFloat = 13, _ weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    // ─── Spacing ───────────────────────────────────────────────
    enum Space {
        static let xs:  CGFloat = 4
        static let s:   CGFloat = 8
        static let m:   CGFloat = 12
        static let l:   CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // ─── Radius ────────────────────────────────────────────────
    enum Radius {
        static let s:   CGFloat = 8
        static let m:   CGFloat = 14
        static let l:   CGFloat = 22
        static let xl:  CGFloat = 28
        static let pill: CGFloat = 999
    }
}

// ─── Helper Color(hex:) ────────────────────────────────────────
extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
