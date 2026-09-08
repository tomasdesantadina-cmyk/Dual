import Foundation

/// User-facing recorder settings. Codable so the app can persist them.
public struct CaptureSettings: Hashable, Codable, Sendable {
    public var quality: VideoQuality
    public var frameRate: Int
    public var codec: VideoCodec
    public var pair: FormatPair
    public var filterID: String
    /// Show the landscape preview above the portrait one.
    public var landscapeOnTop: Bool
    /// Save a still image of the full frame whenever the snapshot button is tapped.
    public var snapshotUsesFilter: Bool
    /// Record and preview the front camera mirrored (what you see is what you get).
    public var mirrorFrontCamera: Bool

    public init(quality: VideoQuality = .hd1080,
                frameRate: Int = 30,
                codec: VideoCodec = .hevc,
                pair: FormatPair = .portraitAndLandscape,
                filterID: String = VideoFilterPreset.passthrough.id,
                landscapeOnTop: Bool = false,
                snapshotUsesFilter: Bool = true,
                mirrorFrontCamera: Bool = true) {
        self.quality = quality
        self.frameRate = frameRate
        self.codec = codec
        self.pair = pair
        self.filterID = filterID
        self.landscapeOnTop = landscapeOnTop
        self.snapshotUsesFilter = snapshotUsesFilter
        self.mirrorFrontCamera = mirrorFrontCamera
    }

    public static let `default` = CaptureSettings()

    public static let supportedFrameRates: [Int] = [24, 30, 60]

    public var filter: VideoFilterPreset { VideoFilterPreset.preset(withID: filterID) }

    public var formatRequirements: CaptureFormatRequirements {
        CaptureFormatRequirements(targetFrameRate: Double(frameRate), quality: quality, pair: pair)
    }

    /// Average bitrate for one output of the given aspect at these settings.
    public func bitrate(for aspect: AspectRatio) -> Int {
        VideoEncodingPlan.averageBitrate(for: quality.outputSize(for: aspect), frameRate: frameRate, codec: codec)
    }

    /// Sanitises values that may have been persisted by an older build.
    public func sanitized() -> CaptureSettings {
        var copy = self
        if !CaptureSettings.supportedFrameRates.contains(copy.frameRate) { copy.frameRate = 30 }
        if !FormatPair.presets.contains(copy.pair) { copy.pair = .portraitAndLandscape }
        if !VideoFilterPreset.all.contains(where: { $0.id == copy.filterID }) { copy.filterID = VideoFilterPreset.passthrough.id }
        return copy
    }
}
