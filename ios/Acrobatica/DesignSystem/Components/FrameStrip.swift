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
                        Image(uiImage: ui)
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

/// Panorama-style strip: mostra l'ULTIMA foto scattata come fascia verticale a
/// sinistra, piena opacità sul bordo che sfuma verso destra in trasparenza.
/// Mima la modalità Panorama di iPhone — l'operatore vede di che pezzo di muro
/// stava chiudendo lo scatto precedente e mantiene un buon overlap.
///
/// Da posizionare nello stesso frame (aspect 3/4) dell'ARPreviewView così
/// il bordo combacia col viewfinder live.
struct PanoramaStripOverlay: View {
    let lastThumbnail: Data?
    var widthFraction: CGFloat = 0.28          // 28% del viewfinder
    var fadeStart: CGFloat = 0.55              // dove inizia il fade (0…1 nello strip)

    var body: some View {
        GeometryReader { geo in
            if let data = lastThumbnail, let ui = UIImage(data: data) {
                let stripW = geo.size.width * widthFraction
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: stripW, height: geo.size.height, alignment: .trailing)
                    .clipped()
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black,                       location: 0.0),
                                .init(color: .black.opacity(0.85),         location: fadeStart),
                                .init(color: .clear,                       location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(alignment: .trailing) {
                        // Hairline gialla al bordo destro per "marcare" la fine del frame
                        // precedente — aiuta l'occhio a posizionare l'overlap.
                        Rectangle()
                            .fill(Theme.yellow.opacity(0.85))
                            .frame(width: 1.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}
