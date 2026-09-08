import DualCore
import SwiftUI

struct ControlTray: View {
    let model: CameraModel

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 2)

            HStack(spacing: 8) {
                Chip(title: model.zoomLabel, systemImage: "plus.magnifyingglass", isEnabled: model.isSessionReady) {
                    model.cycleZoomPreset()
                }
                Chip(title: model.settings.pair.label, systemImage: "aspectratio", isEnabled: model.phase == .idle && model.isSessionReady) {
                    model.cycleFormatPair()
                }
                Chip(title: "Filter",
                     systemImage: "camera.filters",
                     isActive: model.isShowingFilterPicker || !model.selectedFilter.isIdentity) {
                    model.isShowingFilterPicker.toggle()
                }
            }

            ZStack {
                HStack {
                    GalleryThumbnail(model: model)
                    Spacer()
                    HStack(spacing: 10) {
                        RoundIconButton(systemImage: "square.on.square", isEnabled: true) {
                            model.toggleLayout()
                        }
                        RoundIconButton(systemImage: "arrow.triangle.2.circlepath.camera",
                                        isEnabled: model.phase == .idle && model.isSessionReady) {
                            model.flipCamera()
                        }
                    }
                }
                RecordButton(isRecording: model.isCapturing, isEnabled: model.isSessionReady && model.phase != .saving) {
                    model.toggleRecording()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(white: 0.17))
        )
    }
}

struct GalleryThumbnail: View {
    let model: CameraModel

    var body: some View {
        Button {
            model.isShowingLastTake = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                if let image = model.lastTake?.thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if model.phase == .saving {
                    Color.black.opacity(0.4)
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.lastTake == nil)
        .accessibilityLabel("Last take")
    }
}

struct FilterStrip: View {
    let model: CameraModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(VideoFilterPreset.all) { preset in
                    Chip(title: preset.displayName, isActive: preset.id == model.selectedFilter.id) {
                        model.select(filter: preset)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 40)
    }
}
