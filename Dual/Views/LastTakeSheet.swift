import DualCore
import SwiftUI

struct LastTakeSheet: View {
    let model: CameraModel
    let take: LastTake
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let image = take.thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 320)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recorded \(RecordingClock.timecode(seconds: take.duration))")
                            .font(.headline)
                        Text(take.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(take.outputs) { output in
                            HStack {
                                Image(systemName: output.aspect.isPortrait ? "rectangle.portrait" : "rectangle")
                                    .foregroundStyle(.secondary)
                                Text("\(output.aspect.label) clip")
                                Spacer()
                                Text("\(output.outputSize.width) x \(output.outputSize.height)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.16)))

                    HStack(spacing: 8) {
                        Image(systemName: take.savedToPhotos ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(take.savedToPhotos ? .green : .orange)
                        Text(take.savedToPhotos ? "Both clips were added to Photos." : "The clips could not be added to Photos.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !take.pendingURLs.isEmpty {
                        Button {
                            Task {
                                await model.retrySavingLastTake()
                            }
                        } label: {
                            Label("Retry saving to Photos", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(model.phase == .saving)
                    }

                    Button {
                        if let url = URL(string: "photos-redirect://") {
                            openURL(url)
                        }
                    } label: {
                        Label("Open Photos", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Last take")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
