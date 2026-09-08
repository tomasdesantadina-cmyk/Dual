import SwiftUI

struct TopBar: View {
    let model: CameraModel

    var body: some View {
        ZStack {
            TimerPill(text: model.elapsedText, isRecording: model.isCapturing)
            HStack {
                if model.isCapturing {
                    RoundIconButton(systemImage: "xmark") {
                        model.isConfirmingDiscard = true
                    }
                    .transition(.opacity)
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
                Spacer()
                HStack(spacing: 10) {
                    RoundIconButton(systemImage: model.isTorchOn ? "bolt.fill" : "bolt.slash",
                                    isActive: model.isTorchOn,
                                    isEnabled: model.hasTorch) {
                        model.toggleTorch()
                    }
                    RoundIconButton(systemImage: "slider.horizontal.3",
                                    isEnabled: model.phase == .idle) {
                        model.isShowingSettings = true
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}
