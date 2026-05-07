import CoreGraphics
import CoreImage
import UIKit

enum Geometria {

    /// Area di un poligono con la formula del laccio (in unità della coordinata fornita).
    /// Per coordinate normalizzate (0-1) torna una frazione del quadrato unitario.
    static func areaPoligono(_ punti: [CGPoint]) -> Double {
        guard punti.count >= 3 else { return 0 }
        var sum: Double = 0
        for i in 0..<punti.count {
            let j = (i + 1) % punti.count
            sum += Double(punti[i].x) * Double(punti[j].y)
            sum -= Double(punti[j].x) * Double(punti[i].y)
        }
        return abs(sum) / 2.0
    }

    /// Converte un'area normalizzata (rispetto al rettangolo wPx × hPx) in m².
    static func areaNormalizzataInMq(
        _ areaNorm: Double,
        widthPx: Double,
        heightPx: Double,
        pixelPerCm: Double
    ) -> Double {
        guard pixelPerCm > 0 else { return 0 }
        let areaPx2 = areaNorm * widthPx * heightPx
        let areaCm2 = areaPx2 / (pixelPerCm * pixelPerCm)
        return areaCm2 / 10_000
    }

    /// Distanza tra due punti.
    static func distanza(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

enum PerspectiveCorrector {

    /// Applica `CIPerspectiveCorrection` con i 4 angoli normalizzati (TL, TR, BR, BL)
    /// e restituisce JPEG + dimensioni della foto raddrizzata.
    /// I punti sono in coordinate immagine (origine in alto-sx, normalizzate 0-1).
    static func raddrizza(
        jpegData: Data,
        tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint
    ) -> (jpeg: Data, widthPx: Double, heightPx: Double)? {
        guard let uiImg = UIImage(data: jpegData),
              let cg = uiImg.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(uiImg.imageOrientation.exifOrientation))

        let extent = ciImage.extent
        // CIImage usa origine in basso-sx; convertiamo i punti normalizzati (origine top-left) in CI-space.
        func mapped(_ p: CGPoint) -> CGPoint {
            let x = p.x * extent.width
            let y = (1.0 - p.y) * extent.height
            return CGPoint(x: extent.origin.x + x, y: extent.origin.y + y)
        }

        let ciTL = mapped(tl)
        let ciTR = mapped(tr)
        let ciBR = mapped(br)
        let ciBL = mapped(bl)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        // Filter expects CI-coords (origin bottom-left): topLeft/topRight = upper edge.
        filter.setValue(CIVector(cgPoint: ciTL), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: ciTR), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: ciBR), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: ciBL), forKey: "inputBottomLeft")

        guard let out = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cgOut = context.createCGImage(out, from: out.extent) else { return nil }
        let uiOut = UIImage(cgImage: cgOut)
        guard let jpeg = uiOut.jpegData(compressionQuality: 0.9) else { return nil }
        return (jpeg, Double(cgOut.width), Double(cgOut.height))
    }
}

extension UIImage.Orientation {
    var exifOrientation: Int {
        switch self {
        case .up: return 1
        case .down: return 3
        case .left: return 8
        case .right: return 6
        case .upMirrored: return 2
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .rightMirrored: return 7
        @unknown default: return 1
        }
    }
}
