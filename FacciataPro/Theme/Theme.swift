import SwiftUI

/// Tema centralizzato FacciataPro — colori brand EdiliziAcrobatica.
/// Modificare qui per propagare in tutta l'app.
///
/// Riferimenti brand:
/// - Giallo brand: usato per CTA principali, header bar, badge prezzo
/// - Navy scuro: usato per testo principale, icone, accent secondario
/// - Bianco: fondi sezioni
/// - Antracite: testo body
enum Theme {

    // MARK: - Colori brand

    /// Giallo EdiliziAcrobatica (CTA, header, accenti)
    static let yellow = Color(hex: "#F5DC0F")

    /// Navy scuro EdiliziAcrobatica (testo enfatico, icone, accent serio)
    static let navy = Color(hex: "#0F1E48")

    /// Bianco
    static let white = Color.white

    /// Antracite — testo body principale
    static let ink = Color(hex: "#1A1A1A")

    // MARK: - Semantici

    /// Accent principale dell'app (= giallo brand). Usato come `.tint`.
    static let accent = yellow

    /// Colore di sfondo per badge/chip secondari
    static let accentSoft = yellow.opacity(0.18)

    /// Colore primario di testo
    static let textPrimary = ink

    /// Colore secondario di testo (sottotitoli, captions)
    static let textSecondary = navy.opacity(0.6)

    /// Sfondo carte/sezioni
    static let cardBackground = Color(uiColor: .secondarySystemBackground)

    // MARK: - Stati funzionali

    /// Successo / accettato
    static let success = Color(hex: "#1FA463")

    /// Avviso / da completare
    static let warning = Color(hex: "#F5A524")

    /// Errore / rifiutato
    static let danger = Color(hex: "#D9342B")
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v & 0xFF000000) >> 24) / 255
            g = Double((v & 0x00FF0000) >> 16) / 255
            b = Double((v & 0x0000FF00) >> 8)  / 255
            a = Double( v & 0x000000FF)        / 255
        } else {
            r = Double((v & 0xFF0000) >> 16) / 255
            g = Double((v & 0x00FF00) >> 8)  / 255
            b = Double( v & 0x0000FF)        / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
