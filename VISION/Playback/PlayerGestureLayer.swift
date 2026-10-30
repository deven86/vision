import SwiftUI
import UIKit

enum PlayerPan {
    case began
    case changed(translation: CGPoint, width: CGFloat)
    case ended
}

/// UIKit gesture layer under the player controls:
/// - single tap: show/hide controls
/// - double tap left/right half: back/forward 10 s
/// - horizontal swipe anywhere: scrub (like the iOS video player — no need to grab the dot)
struct PlayerGestureLayer: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onDoubleTap: (_ forward: Bool) -> Void
    var onPan: (PlayerPan) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.singleTapped))
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = coordinator
        view.addGestureRecognizer(pan)

        coordinator.parent = self
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureLayer?

        @objc func singleTapped() { parent?.onSingleTap() }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            parent?.onDoubleTap(gesture.location(in: view).x > view.bounds.midX)
        }

        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                parent?.onPan(.began)
            case .changed:
                parent?.onPan(.changed(translation: gesture.translation(in: view), width: max(1, view.bounds.width)))
            case .ended, .cancelled, .failed:
                parent?.onPan(.ended)
            default:
                break
            }
        }

        /// Only horizontal swipes scrub, so vertical movement never seeks by accident.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}
