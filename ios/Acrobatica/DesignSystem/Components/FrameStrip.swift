import SwiftUI

/// Strip orizzontale di thumbnail degli scatti già fatti.
/// Mostra le ultime N foto a destra (le più recenti per prime).
struct FrameStrip: View {
    let thumbnails: [Data]      // raw JPEG/PNG bytes
    var maxVisible: Int = 30

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(thumbnails.suffix(maxVisible).reversed().enumerated()), id: \.offset) { _, data in
                    if let ui = UIImage(data: data) {
                        Image(uiImage: ui.acrobaticaPortraitOriented())
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(.white.opacity(0.6), lineWidth: 1)
                            )
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private extension UIImage {
    func acrobaticaPortraitOriented() -> UIImage {
        guard size.width > size.height else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.height, height: size.width),
                                                format: format)
        return renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: size.height / 2, y: size.width / 2)
            cg.rotate(by: .pi / 2)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2,
                            width: size.width, height: size.height))
        }
    }
}

/// Picture-in-Picture overlay: mostra l'ULTIMA foto scattata come miniatura in
/// alto a sinistra del viewfinder, a piena scala (niente cropping). L'operatore
/// può confrontare cosa c'è in quel quadrato con la vista live per mantenere
/// continuità mentre pana lateralmente.
struct PiPLastShotOverlay: View {
    let lastThumbnail: Data?
    var widthFraction: CGFloat = 0.36     // miniatura ~36% larghezza viewfinder

    var body: some View {
        GeometryReader { geo in
            if let data = lastThumbnail, let ui = UIImage(data: data) {
                let pipW = geo.size.width * widthFraction
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(width: pipW)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.yellow, lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                    .padding(.leading, 12)
                    .padding(.top, 80)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}
