import DualCore
import SwiftUI

struct SettingsSheet: View {
    let model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CaptureSettings

    init(model: CameraModel, initialSettings: CaptureSettings) {
        self.model = model
        _draft = State(initialValue: initialSettings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Quality", selection: $draft.quality) {
                        ForEach(VideoQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    Picker("Frame rate", selection: $draft.frameRate) {
                        ForEach(CaptureSettings.supportedFrameRates, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    Picker("Codec", selection: $draft.codec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                    Picker("Formats", selection: $draft.pair) {
                        ForEach(FormatPair.presets) { pair in
                            Text(pair.label).tag(pair)
                        }
                    }
                }

                Section("Layout") {
                    Toggle("Landscape preview on top", isOn: $draft.landscapeOnTop)
                    Toggle("Mirror front camera", isOn: $draft.mirrorFrontCamera)
                }

                Section("Camera") {
                    LabeledContent("Sensor format", value: model.formatLabel.isEmpty ? "Not ready" : model.formatLabel)
                    LabeledContent("Audio", value: model.hasAudio ? "On" : "Microphone unavailable")
                    Text("Both clips are recorded from the same sensor frame. The landscape clip keeps the full width and the portrait clip keeps the full height, so the landscape video shows a wider view.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Files") {
                    Text("Each take produces two QuickTime files that are added to your Photos library. The most recent take is also kept inside the app until the next recording.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: draft) { _, newValue in
                model.updateSettings(newValue)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
