import DualCore
import SwiftUI
import UIKit

struct CameraScreen: View {
    @Bindable var model: CameraModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(model: model)
                    .padding(.top, 4)

                previews
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                Spacer(minLength: 10)

                if model.isShowingFilterPicker {
                    FilterStrip(model: model)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                ControlTray(model: model)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            if model.snapshotFlash {
                Color.white
                    .ignoresSafeArea()
                    .opacity(0.6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            SnapshotButton(isEnabled: model.isSessionReady) {
                model.captureSnapshot()
            }
            .padding(.trailing, 18)
            .padding(.top, 82)
        }
        .overlay(alignment: .top) {
            if let message = model.interruptionMessage ?? model.pressureWarning {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.orange.opacity(0.9)))
                    .padding(.top, 60)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isShowingFilterPicker)
        .animation(.easeInOut(duration: 0.2), value: model.interruptionMessage)
        .animation(.easeInOut(duration: 0.2), value: model.pressureWarning)
        .alert(model.alert?.title ?? "", isPresented: isShowingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert?.message ?? "")
        }
        .confirmationDialog("Discard this recording?", isPresented: $model.isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                model.discardRecording()
            }
            Button("Keep recording", role: .cancel) {}
        }
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsSheet(model: model, initialSettings: model.settings)
        }
        .sheet(isPresented: $model.isShowingLastTake) {
            if let take = model.lastTake {
                LastTakeSheet(model: model, take: take)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var isShowingAlert: Binding<Bool> {
        Binding(
            get: { model.alert != nil },
            set: { isPresented in
                if !isPresented { model.alert = nil }
            }
        )
    }

    private var orderedAspects: [AspectRatio] {
        let pair = model.settings.pair
        return model.settings.landscapeOnTop ? [pair.secondary, pair.primary] : [pair.primary, pair.secondary]
    }

    private func target(for aspect: AspectRatio) -> PreviewTarget {
        aspect == model.settings.pair.primary ? model.engine.primaryPreview : model.engine.secondaryPreview
    }

    private var previews: some View {
        GeometryReader { proxy in
            let layout = DualCore.PreviewLayout.compute(availableWidth: Double(proxy.size.width),
                                               availableHeight: Double(proxy.size.height),
                                               aspects: orderedAspects)
            VStack(spacing: CGFloat(layout.spacing)) {
                ForEach(layout.panes) { pane in
                    PreviewPane(model: model, target: target(for: pane.aspect), aspect: pane.aspect)
                        .frame(width: CGFloat(pane.width), height: CGFloat(pane.height))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    model.pinchChanged(value.magnification)
                }
                .onEnded { _ in
                    model.pinchEnded()
                }
        )
    }
}
