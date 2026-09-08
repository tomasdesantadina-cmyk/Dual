import AVKit
import SwiftUI
import UIKit

/// Routes the hardware capture buttons (Camera Control on iPhone 16 and later,
/// the Action button and the volume buttons while the camera runs) to the app,
/// so pressing them starts and stops recording like in the system camera.
struct CaptureEventsView: UIViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> CaptureEventsHostView {
        let view = CaptureEventsHostView()
        view.backgroundColor = .clear
        view.install(action: action)
        view.setEnabled(isEnabled)
        return view
    }

    func updateUIView(_ uiView: CaptureEventsHostView, context: Context) {
        uiView.install(action: action)
        uiView.setEnabled(isEnabled)
    }
}

final class CaptureEventsHostView: UIView {
    /// Stored as a plain UIInteraction so the property needs no availability annotation.
    private var interaction: (any UIInteraction)?
    private var action: (() -> Void)?

    func install(action: @escaping () -> Void) {
        self.action = action
        guard interaction == nil else { return }
        if #available(iOS 17.2, *) {
            let captureInteraction = AVCaptureEventInteraction { [weak self] event in
                // "Ended" is the press-up of the button, the moment the system camera acts.
                if event.phase == .ended {
                    self?.action?()
                }
            }
            addInteraction(captureInteraction)
            interaction = captureInteraction
        }
    }

    /// Disabled interactions hand the buttons back to the system (volume, etc.).
    func setEnabled(_ enabled: Bool) {
        if #available(iOS 17.2, *), let captureInteraction = interaction as? AVCaptureEventInteraction {
            captureInteraction.isEnabled = enabled
        }
    }
}
