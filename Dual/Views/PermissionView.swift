import SwiftUI

struct PermissionView: View {
    let model: CameraModel
    let isDenied: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white)
            Text("Dual")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Record one shot as two videos at once: a 9:16 portrait clip and a 16:9 landscape clip, both saved to Photos.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 32)
            Spacer()
            if isDenied {
                VStack(spacing: 12) {
                    Text("Camera access is off. Turn it on in Settings to start recording.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    Button {
                        model.openSystemSettings()
                    } label: {
                        Text("Open Settings")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(.horizontal, 32)
            } else {
                ProgressView()
                    .tint(.white)
                Text("Waiting for camera and microphone permission")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
