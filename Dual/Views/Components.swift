import SwiftUI

extension View {
    /// Liquid Glass (iOS 26 and later) with a translucent fill on earlier systems.
    /// Glass belongs on controls that float over content, never on other glass.
    @ViewBuilder
    func adaptiveGlass<S: Shape>(in shape: S, fallback: Color, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(shape.fill(fallback))
        }
    }
}

/// Groups neighbouring glass controls so they render together and can merge.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// Capsule-shaped control used for zoom, format and filter in the tray.
struct Chip: View {
    let title: String
    var systemImage: String? = nil
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .adaptiveGlass(in: Capsule(),
                           fallback: Color.white.opacity(isActive ? 0.30 : 0.14),
                           tint: isActive ? Color.white.opacity(0.35) : nil,
                           interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Round translucent icon button used in the top bar and the tray.
struct RoundIconButton: View {
    let systemImage: String
    var size: CGFloat = 44
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .adaptiveGlass(in: Circle(),
                               fallback: Color.white.opacity(isActive ? 0.32 : 0.14),
                               tint: isActive ? Color.white.opacity(0.35) : nil,
                               interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The red pill showing the elapsed recording time.
struct TimerPill: View {
    let text: String
    let isRecording: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .adaptiveGlass(in: Capsule(),
                           fallback: isRecording ? Color.red : Color.white.opacity(0.14),
                           tint: isRecording ? Color.red : nil)
            .animation(.easeInOut(duration: 0.2), value: isRecording)
    }
}

/// The big shutter: red disc with a white ring; shows a stop square while recording.
struct RecordButton: View {
    let isRecording: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(Color.red)
                    .frame(width: 66, height: 66)
                if isRecording {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 26, height: 26)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.15), value: isRecording)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

/// Side button that grabs a still frame while previewing or recording.
struct SnapshotButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color.white.opacity(0.7))
                .frame(width: 38, height: 38)
                .frame(width: 58, height: 58)
                .adaptiveGlass(in: Circle(), fallback: Color.white.opacity(0.22), interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel("Take snapshot")
    }
}

/// Yellow square shown briefly where the user tapped to focus.
struct FocusReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 64, height: 64)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .allowsHitTesting(false)
    }
}
