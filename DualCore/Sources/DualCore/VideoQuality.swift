import Foundation

/// Output resolution tier. The short side is fixed per tier so that
/// 16:9 -> 1920x1080, 9:16 -> 1080x1920, 1:1 -> 1080x1080, 4:5 -> 1080x1350.
public enum VideoQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case hd1080 = "1080p"
    case uhd4K = "4K"

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    /// The fixed short side of any output at this quality.
    public var shortSide: Int {
        switch self {
        case .hd1080: return 1080
        case .uhd4K: return 2160
        }
    }

    /// The long side of a 16:9 / 9:16 output at this quality.
    public var longSide16x9: Int {
        switch self {
        case .hd1080: return 1920
        case .uhd4K: return 3840
        }
    }

    /// Output dimensions for the given aspect ratio, even-snapped.
    public func outputSize(for aspect: AspectRatio) -> PixelSize {
        if aspect.isPortrait {
            return PixelSize(width: shortSide, height: evenRound(Double(shortSide) / aspect.value))
        } else {
            return PixelSize(width: evenRound(Double(shortSide) * aspect.value), height: shortSide)
        }
    }
}

/// Video codec choice for the asset writers.
public enum VideoCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    /// Approximate bits per pixel per frame, tuned to land near the system camera's
    /// rates (about 10 Mbps for 1080p30 H.264, 30 Mbps for 4K30 HEVC).
    var bitsPerPixel: Double {
        switch self {
        case .h264: return 0.16
        case .hevc: return 0.12
        }
    }
}

/// Bitrate planning that mirrors what the system camera roughly produces.
public enum VideoEncodingPlan {
    public static let minimumBitrate = 2_000_000
    public static let maximumBitrate = 90_000_000

    /// Average bitrate in bits per second for a given output.
    public static func averageBitrate(for size: PixelSize, frameRate: Int, codec: VideoCodec) -> Int {
        guard !size.isEmpty, frameRate > 0 else { return minimumBitrate }
        let raw = Double(size.pixelCount) * Double(frameRate) * codec.bitsPerPixel
        let clamped = min(Double(maximumBitrate), max(Double(minimumBitrate), raw))
        return Int(clamped.rounded())
    }
}
