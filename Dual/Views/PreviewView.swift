import AVFoundation
import DualCore
import SwiftUI
import UIKit

/// Hosts one AVSampleBufferDisplayLayer inside SwiftUI.
struct PreviewView: UIViewRepresentable {
    let target: PreviewTarget

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.attach(target)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.attach(target)
    }
}

final class PreviewHostView: UIView {
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private weak var target: PreviewTarget?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        clipsToBounds = true
    }

    func attach(_ newTarget: PreviewTarget) {
        target = newTarget
        let newLayer = newTarget.layer
        guard displayLayer !== newLayer else { return }
        displayLayer?.removeFromSuperlayer()
        newLayer.removeFromSuperlayer()
        layer.addSublayer(newLayer)
        displayLayer = newLayer
        setNeedsLayout()
        if window != nil {
            newTarget.hostIsOnScreen = true
            newTarget.onScreenChanged?(true)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let onScreen = window != nil
        target?.hostIsOnScreen = onScreen
        target?.onScreenChanged?(onScreen)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }
}

/// One preview pane: aspect-locked, rounded, tappable for focus.
struct PreviewPane: View {
    let model: CameraModel
    let target: PreviewTarget
    let aspect: AspectRatio

    var body: some View {
        GeometryReader { proxy in
            PreviewView(target: target)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            guard let output = model.output(for: aspect) else { return }
                            let location = value.location
                            let width = max(proxy.size.width, 1)
                            let height = max(proxy.size.height, 1)
                            let point = UnitPoint2D(x: Double(location.x / width), y: Double(location.y / height))
                            model.focus(atPreviewPoint: point, in: output, indicatorLocation: location, paneID: aspect.label)
                        }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            model.toggleExposureFocusLock()
                        }
                )
                .overlay {
                    if let indicator = model.focusIndicator, indicator.paneID == aspect.label {
                        FocusReticle()
                            .position(indicator.location)
                            .transition(.opacity)
                    }
                }
        }
        .overlay(alignment: .top) {
            if model.isExposureFocusLocked {
                Text("AE/AF LOCK")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow))
                    .padding(.top, 8)
            }
        }
        .aspectRatio(CGFloat(aspect.value), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            Text(aspect.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .padding(8)
        }
    }
}
