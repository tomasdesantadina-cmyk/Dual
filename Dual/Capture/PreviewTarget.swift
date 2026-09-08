import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UIKit

/// A live preview surface backed by AVSampleBufferDisplayLayer. Processed
/// frames are wrapped in CMSampleBuffers flagged for immediate display, so the
/// layer shows exactly what is being recorded (crop, zoom and filter included).
final class PreviewTarget {

    let layer: AVSampleBufferDisplayLayer

    /// Main thread. True while the hosting view is inside a window. The rotation
    /// coordinator's preview angle is only meaningful for an on-screen layer.
    var hostIsOnScreen = false
    /// Main thread. Called by the host view when it enters or leaves a window.
    var onScreenChanged: ((Bool) -> Void)?

    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = UIColor.black.cgColor
    }

    /// Thread-safe: AVSampleBufferDisplayLayer accepts enqueues from any queue.
    func display(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let sampleBuffer = PreviewTarget.makeSampleBuffer(from: pixelBuffer, presentationTime: presentationTime) else { return }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            layer.flush()
        }
        if layer.isReadyForMoreMediaData {
            layer.enqueue(sampleBuffer)
        }
    }

    func clear() {
        layer.flushAndRemoveImage()
    }

    private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                        imageBuffer: pixelBuffer,
                                                                        formatDescriptionOut: &formatDescription)
        guard formatStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime.isValid ? presentationTime : .zero,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                                    imageBuffer: pixelBuffer,
                                                                    formatDescription: formatDescription,
                                                                    sampleTiming: &timing,
                                                                    sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else { return nil }

        // Ask the layer to show the frame as soon as it arrives instead of
        // scheduling it against a timebase.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}
