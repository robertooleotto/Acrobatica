import SwiftUI
import UIKit

/// Fase di un gesto continuo (drag / pinch / pan a due dita).
enum FaseGesto {
    case inizio, cambiamento, fine
}

/// Layer UIKit trasparente che cattura i gesti touch-first dell'editor zone
/// (MarcaturaFacciataView). SwiftUI puro non espone il punto del pinch
/// prima di iOS 17, quindi usiamo UIGestureRecognizer:
///  - pinch        → zoom verso il punto di pinch (delta incrementale)
///  - pan 2 dita   → pan della vista (traslazione incrementale)
///  - pan 1 dito   → drag (disegno rettangolo / maniglie vertici / mano)
///  - tap          → aggiungi vertice / seleziona
///  - double-tap   → fit dell'immagine
struct EditorGestureView: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onDoubleTap: (CGPoint) -> Void
    /// (fase, posizione corrente nello spazio della vista)
    var onDrag: (FaseGesto, CGPoint) -> Void
    /// (fase, delta scala incrementale, centro del pinch)
    var onPinch: (FaseGesto, CGFloat, CGPoint) -> Void
    /// (fase, traslazione incrementale)
    var onPanDueDita: (FaseGesto, CGSize) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let c = context.coordinator

        let doppio = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doppioTap(_:)))
        doppio.numberOfTapsRequired = 2

        let singolo = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        singolo.require(toFail: doppio)

        let drag = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.drag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1

        let panDue = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.panDueDita(_:)))
        panDue.minimumNumberOfTouches = 2
        panDue.maximumNumberOfTouches = 2

        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))

        for g in [doppio, singolo, drag, panDue, pinch] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }
        c.pinchRecognizer = pinch
        c.panDueRecognizer = panDue
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: EditorGestureView
        weak var pinchRecognizer: UIPinchGestureRecognizer?
        weak var panDueRecognizer: UIPanGestureRecognizer?

        init(_ parent: EditorGestureView) { self.parent = parent }

        @objc func tap(_ g: UITapGestureRecognizer) {
            parent.onTap(g.location(in: g.view))
        }

        @objc func doppioTap(_ g: UITapGestureRecognizer) {
            parent.onDoubleTap(g.location(in: g.view))
        }

        @objc func drag(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let pos = g.location(in: view)
            switch g.state {
            case .began:
                // Punto di partenza reale (il pan parte dopo qualche pt di movimento)
                let t = g.translation(in: view)
                let inizio = CGPoint(x: pos.x - t.x, y: pos.y - t.y)
                parent.onDrag(.inizio, inizio)
                parent.onDrag(.cambiamento, pos)
            case .changed:
                parent.onDrag(.cambiamento, pos)
            case .ended, .cancelled, .failed:
                parent.onDrag(.fine, pos)
            default:
                break
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let view = g.view else { return }
            let centro = g.location(in: view)
            switch g.state {
            case .began:
                parent.onPinch(.inizio, 1, centro)
            case .changed:
                parent.onPinch(.cambiamento, g.scale, centro)
                g.scale = 1   // delta incrementale
            case .ended, .cancelled, .failed:
                parent.onPinch(.fine, 1, centro)
            default:
                break
            }
        }

        @objc func panDueDita(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let t = g.translation(in: view)
            let delta = CGSize(width: t.x, height: t.y)
            switch g.state {
            case .began:
                parent.onPanDueDita(.inizio, .zero)
            case .changed:
                parent.onPanDueDita(.cambiamento, delta)
                g.setTranslation(.zero, in: view)
            case .ended, .cancelled, .failed:
                parent.onPanDueDita(.fine, .zero)
            default:
                break
            }
        }

        /// Pinch e pan a due dita lavorano insieme (come in Blender / Mappe).
        func gestureRecognizer(_ a: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            let coppia: Set<ObjectIdentifier> = [ObjectIdentifier(a), ObjectIdentifier(b)]
            var attesa: Set<ObjectIdentifier> = []
            if let p = pinchRecognizer { attesa.insert(ObjectIdentifier(p)) }
            if let d = panDueRecognizer { attesa.insert(ObjectIdentifier(d)) }
            return coppia == attesa
        }
    }
}
