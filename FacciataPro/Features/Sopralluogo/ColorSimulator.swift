import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum ColorSimulator {

    /// Applica un colore alla foto preservando la luminanza dell'originale.
    /// Algoritmo: 1) desatura → grayscale Y, 2) moltiplica per il colore target.
    /// Risultato: ombre, luci e dettagli del muro restano, cambia solo la cromia.
    static func simula(jpegData: Data, hex: String) -> Data? {
        guard let ui = UIImage(data: jpegData),
              let cg = ui.cgImage else { return nil }
        let exif = Int32(ui.imageOrientation.exifOrientation)
        let input = CIImage(cgImage: cg).oriented(forExifOrientation: exif)

        // 1) Desatura → luminanza
        let desat = CIFilter.colorControls()
        desat.inputImage = input
        desat.saturation = 0
        desat.brightness = 0
        desat.contrast = 1
        guard let gray = desat.outputImage else { return nil }

        // 2) Genera immagine costante del colore target
        guard let target = uiColor(fromHex: hex) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        target.getRed(&r, green: &g, blue: &b, alpha: &a)
        let solid = CIImage(color: CIColor(red: r, green: g, blue: b))
            .cropped(to: gray.extent)

        // 3) Multiply: (Y/255) * targetColor → preserva luminanza
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = solid
        multiply.backgroundImage = gray
        guard let blended = multiply.outputImage else { return nil }

        let ctx = CIContext()
        guard let outCG = ctx.createCGImage(blended, from: blended.extent) else { return nil }
        let outUI = UIImage(cgImage: outCG)
        return outUI.jpegData(compressionQuality: 0.85)
    }

    static func uiColor(fromHex hex: String) -> UIColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var v: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&v) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v & 0xFF000000) >> 24) / 255
            g = CGFloat((v & 0x00FF0000) >> 16) / 255
            b = CGFloat((v & 0x0000FF00) >> 8)  / 255
            a = CGFloat( v & 0x000000FF)        / 255
        } else {
            r = CGFloat((v & 0xFF0000) >> 16) / 255
            g = CGFloat((v & 0x00FF00) >> 8)  / 255
            b = CGFloat( v & 0x0000FF)        / 255
            a = 1
        }
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    static func hex(from color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()),
                      Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
    }
}

/// Palette base — colori facciate tipici.
enum PalettiTinte {
    struct Tinta: Identifiable, Hashable {
        let id = UUID()
        let nome: String
        let hex: String
    }

    static let base: [Tinta] = [
        .init(nome: "Beige",         hex: "#F2D9B3"),
        .init(nome: "Sabbia",        hex: "#EBCC99"),
        .init(nome: "Terracotta",    hex: "#D9A580"),
        .init(nome: "Mattone",       hex: "#A67259"),
        .init(nome: "Panna",         hex: "#F2EDD9"),
        .init(nome: "Verde salvia",  hex: "#CCD9CC"),
        .init(nome: "Azzurro",       hex: "#8CB2BF"),
        .init(nome: "Glicine",       hex: "#D9CCE6")
    ]
}
