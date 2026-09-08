import AVFoundation
import DualCore
import SwiftUI
import UIKit

/// Hosts one AVSampleBufferDisplayLayer inside SwiftUI.
struct PreviewView: UIViewRepresentable {
    let target: PreviewTarget

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.attach(target.layer)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.attach(target.layer)
    }
}

final class PreviewHostView: UIView {
    private weak var displayLayer: AVSampleBufferDisplayLayer?

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

    func attach(_ newLayer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== newLayer else { return }
        displayLayer?.removeFromSuperlayer()
        newLayer.removeFromSuperlayer()
        layer.addSublayer(newLayer)
        displayLayer = newLayer
        setNeedsLayout()
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
                .overlay {
                    if let indicator = model.focusIndicator, indicator.paneID == aspect.label {
                        FocusReticle()
                            .position(indicator.location)
                            .transition(.opacity)
                    }
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
