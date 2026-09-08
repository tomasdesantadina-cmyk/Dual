import AVFoundation
import CoreMedia
import CoreVideo
import DualCore
import Foundation

/// Writes one output stream (video from pixel buffers + audio samples) to a
/// QuickTime file with AVAssetWriter. Not thread-safe: drive it from the
/// capture data queue.
final class ClipWriter {

    enum State {
        case prepared
        case writing
        case finishing
        case finished
        case failed
    }

    enum WriterError: LocalizedError {
        case cannotApplySettings
        case cannotAddInput
        case cannotStart(Error?)
        case notWriting
        case underlying(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotApplySettings: return "The video settings are not supported on this device."
            case .cannotAddInput: return "Could not add an input to the movie writer."
            case .cannotStart(let error): return error?.localizedDescription ?? "The movie writer could not start."
            case .notWriting: return "The movie writer was not recording."
            case .underlying(let error): return error?.localizedDescription ?? "The movie writer failed."
            }
        }
    }

    let url: URL
    let framing: FramingOutput
    private(set) var state: State = .prepared
    private(set) var lastVideoTime: CMTime = .invalid
    private(set) var appendedFrames = 0

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?

    /// Creates the file and calls startWriting() immediately so failures surface
    /// before the first frame. The timeline starts later with `start(at:)`.
    init(url: URL,
         framing: FramingOutput,
         codec: VideoCodec,
         frameRate: Int,
         bitrate: Int,
         audioSettings: [String: Any]?) throws {
        self.url = url
        self.framing = framing

        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        let codecType: AVVideoCodecType
        switch codec {
        case .h264:
            codecType = .h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            codecType = .hevc
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType.rawValue,
            AVVideoWidthKey: framing.outputSize.width,
            AVVideoHeightKey: framing.outputSize.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw WriterError.cannotApplySettings
        }

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        // Pixels are already upright, so no display transform is needed.
        videoInput.transform = .identity
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: framing.outputSize.width,
                kCVPixelBufferHeightKey as String: framing.outputSize.height,
            ]
        )
        guard writer.canAdd(videoInput) else { throw WriterError.cannotAddInput }
        writer.add(videoInput)

        if let audioSettings, writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            let error = writer.error
            try? FileManager.default.removeItem(at: url)
            throw WriterError.cannotStart(error)
        }
    }

    var hasAudio: Bool { audioInput != nil }
    var error: Error? { writer.error }

    /// True when a video frame can be appended right now.
    var isReadyForVideo: Bool {
        state == .writing && videoInput.isReadyForMoreMediaData
    }

    /// True when an audio buffer can be appended right now (false without audio).
    var isReadyForAudio: Bool {
        guard state == .writing, let audioInput else { return false }
        return audioInput.isReadyForMoreMediaData
    }

    /// Starts the timeline at `time` (the first video frame's timestamp).
    func start(at time: CMTime) -> Bool {
        guard state == .prepared, writer.status == .writing else {
            state = .failed
            return false
        }
        writer.startSession(atSourceTime: time)
        state = .writing
        return true
    }

    @discardableResult
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard isReadyForVideo else { return false }
        // Timestamps must strictly increase.
        if lastVideoTime.isValid, time <= lastVideoTime { return false }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
            appendedFrames += 1
            return true
        }
        if writer.status == .failed { state = .failed }
        return false
    }

    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard isReadyForAudio, let audioInput else { return false }
        if audioInput.append(sampleBuffer) { return true }
        if writer.status == .failed { state = .failed }
        return false
    }

    /// Ends the timeline at `endTime`, marks the inputs finished and finalises the file.
    func finish(endTime: CMTime, completion: @escaping (Result<URL, Error>) -> Void) {
        switch state {
        case .writing:
            state = .finishing
            if endTime.isValid, !lastVideoTime.isValid || endTime > lastVideoTime {
                writer.endSession(atSourceTime: endTime)
            }
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            let url = self.url
            writer.finishWriting { [weak self] in
                guard let self else { return }
                if self.writer.status == .completed {
                    self.state = .finished
                    completion(.success(url))
                } else {
                    self.state = .failed
                    completion(.failure(WriterError.underlying(self.writer.error)))
                }
            }
        case .failed:
            cancel()
            completion(.failure(WriterError.underlying(writer.error)))
        default:
            cancel()
            completion(.failure(WriterError.notWriting))
        }
    }

    /// Abandons the recording and deletes the partial file.
    func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        state = .failed
        try? FileManager.default.removeItem(at: url)
    }
}
