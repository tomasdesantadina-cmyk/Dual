import AVFoundation
import CoreMedia
import CoreVideo
import DualCore
import Foundation

/// Coordinates one ClipWriter per output so both clips share the exact same
/// timeline: same start time, same frames, same audio, same end time. Frames and
/// audio are appended to both writers or to neither, so the files never drift.
/// Not thread-safe: drive it from the capture data queue.
final class DualRecorder {

    struct Clip {
        let url: URL
        let framing: FramingOutput
    }

    enum RecorderError: LocalizedError {
        case nothingRecorded
        case writerFailed(Error)

        var errorDescription: String? {
            switch self {
            case .nothingRecorded: return "No frames were recorded."
            case .writerFailed(let error): return error.localizedDescription
            }
        }
    }

    let startedAt = Date()
    private let writers: [ClipWriter]
    private(set) var isStarted = false
    private(set) var droppedVideoFrames = 0
    private var startTime: CMTime = .invalid
    private var lastFrameTime: CMTime = .invalid
    private var lastFrameDuration: CMTime = .invalid
    private let nominalFrameDuration: CMTime

    init(plan: FramingPlan,
         settings: CaptureSettings,
         audioSettings: [String: Any]?,
         directory: URL,
         baseName: String) throws {
        nominalFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.frameRate)))
        var created: [ClipWriter] = []
        do {
            for output in plan.outputs {
                let suffix = "\(output.aspect.width)x\(output.aspect.height)"
                let url = directory.appendingPathComponent("\(baseName)-\(suffix).mov")
                let writer = try ClipWriter(url: url,
                                            framing: output,
                                            codec: settings.codec,
                                            frameRate: settings.frameRate,
                                            bitrate: settings.bitrate(for: output.aspect),
                                            audioSettings: audioSettings)
                created.append(writer)
            }
        } catch {
            created.forEach { $0.cancel() }
            throw error
        }
        writers = created
    }

    var clips: [Clip] { writers.map { Clip(url: $0.url, framing: $0.framing) } }

    /// Seconds of video appended so far.
    var recordedDuration: Double {
        guard startTime.isValid, lastFrameTime.isValid else { return 0 }
        return max(0, CMTimeGetSeconds(CMTimeSubtract(lastFrameTime, startTime)))
    }

    /// Appends one processed frame per writer. The first call starts all writers
    /// at the same source time. If any writer is not ready the frame is dropped
    /// for all of them.
    func appendVideo(_ outputs: [FrameProcessor.RenderedOutput], at time: CMTime) {
        guard time.isValid else { return }

        // Every writer needs a rendered frame for its framing.
        var matched: [(ClipWriter, CVPixelBuffer)] = []
        for writer in writers {
            guard let rendered = outputs.first(where: { $0.framing.aspect == writer.framing.aspect }) else {
                droppedVideoFrames += 1
                return
            }
            matched.append((writer, rendered.pixelBuffer))
        }

        if !isStarted {
            var allStarted = true
            for writer in writers {
                if !writer.start(at: time) {
                    allStarted = false
                }
            }
            guard allStarted else {
                writers.forEach { $0.cancel() }
                return
            }
            isStarted = true
            startTime = time
        }

        guard writers.allSatisfy({ $0.isReadyForVideo }) else {
            droppedVideoFrames += 1
            return
        }
        for (writer, buffer) in matched {
            writer.appendVideo(buffer, at: time)
        }
        if lastFrameTime.isValid {
            let delta = CMTimeSubtract(time, lastFrameTime)
            if delta.isValid, CMTimeGetSeconds(delta) > 0 { lastFrameDuration = delta }
        }
        lastFrameTime = time
    }

    /// Fans one audio sample buffer out to every writer, or to none.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isStarted else { return }
        let audioWriters = writers.filter { $0.hasAudio }
        guard !audioWriters.isEmpty, audioWriters.allSatisfy({ $0.isReadyForAudio }) else { return }
        for writer in audioWriters {
            writer.appendAudio(sampleBuffer)
        }
    }

    /// Finalises all clips with one shared end time. Completion fires once, on a
    /// background queue, with every clip URL or the first error encountered.
    func finish(completion: @escaping (Result<[Clip], Error>) -> Void) {
        guard isStarted, lastFrameTime.isValid else {
            writers.forEach { $0.cancel() }
            completion(.failure(RecorderError.nothingRecorded))
            return
        }
        let frameDuration = lastFrameDuration.isValid ? lastFrameDuration : nominalFrameDuration
        let endTime = CMTimeAdd(lastFrameTime, frameDuration)

        let group = DispatchGroup()
        let lock = NSLock()
        var firstError: Error?
        for writer in writers {
            group.enter()
            writer.finish(endTime: endTime) { result in
                if case .failure(let error) = result {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
                group.leave()
            }
        }
        let clips = self.clips
        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            if let firstError {
                clips.forEach { try? FileManager.default.removeItem(at: $0.url) }
                completion(.failure(RecorderError.writerFailed(firstError)))
            } else {
                completion(.success(clips))
            }
        }
    }

    /// Discards everything written so far.
    func cancel() {
        writers.forEach { $0.cancel() }
    }
}
