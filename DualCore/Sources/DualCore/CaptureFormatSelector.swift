import Foundation

/// Platform-neutral description of one AVCaptureDevice.Format.
/// `width`/`height` are the sensor (landscape) dimensions as reported by the format.
public struct CaptureFormatCandidate: Hashable, Codable, Sendable, CustomStringConvertible {
    public let index: Int
    public let width: Int
    public let height: Int
    public let maxFrameRate: Double
    public let isBinned: Bool
    /// FourCC of the pixel format, e.g. "420v", "420f", "x420".
    public let pixelFormat: String

    public init(index: Int, width: Int, height: Int, maxFrameRate: Double, isBinned: Bool, pixelFormat: String) {
        self.index = index
        self.width = width
        self.height = height
        self.maxFrameRate = maxFrameRate
        self.isBinned = isBinned
        self.pixelFormat = pixelFormat
    }

    public var sensorSize: PixelSize { PixelSize(width: width, height: height) }
    /// The frame as delivered when the phone is held upright (rotated 90 degrees).
    public var portraitSize: PixelSize { PixelSize(width: height, height: width) }

    public var description: String {
        "#\(index) \(width)x\(height)@\(Int(maxFrameRate)) \(pixelFormat)\(isBinned ? " binned" : "")"
    }
}

/// What the recorder needs from a capture format.
public struct CaptureFormatRequirements: Hashable, Sendable {
    public var targetFrameRate: Double
    public var quality: VideoQuality
    public var pair: FormatPair
    /// Upper bound on the sensor long side to keep processing affordable.
    public var maxLongSide: Int
    /// Pixel formats the pipeline can consume (8-bit 4:2:0 only by default).
    public var allowedPixelFormats: Set<String>
    /// Sensor pixel count above which a steep penalty applies, so the 1080p tier
    /// never streams a 12 MP format when a smaller one would do.
    public var softMaxPixels: Int
    /// Whether making frames upright rotates them by 90 or 270 degrees (true for
    /// landscape-mounted sensors such as every rear camera; false for the
    /// portrait-mounted square front sensor on iPhone 17).
    public var uprightSwapsDimensions: Bool

    public init(targetFrameRate: Double = 30,
                quality: VideoQuality = .hd1080,
                pair: FormatPair = .portraitAndLandscape,
                maxLongSide: Int = 4096,
                allowedPixelFormats: Set<String> = ["420v", "420f"],
                softMaxPixels: Int? = nil,
                uprightSwapsDimensions: Bool = true) {
        self.targetFrameRate = targetFrameRate
        self.quality = quality
        self.pair = pair
        self.maxLongSide = maxLongSide
        self.allowedPixelFormats = allowedPixelFormats
        self.softMaxPixels = softMaxPixels ?? CaptureFormatRequirements.defaultSoftMaxPixels(for: quality)
        self.uprightSwapsDimensions = uprightSwapsDimensions
    }

    /// The frame size the pipeline will see for a candidate once it is upright.
    public func uprightSize(of candidate: CaptureFormatCandidate) -> PixelSize {
        uprightSwapsDimensions ? candidate.portraitSize : candidate.sensorSize
    }

    /// 1080p is happy with a 5 MP sensor frame; 4K needs the 12 MP formats.
    public static func defaultSoftMaxPixels(for quality: VideoQuality) -> Int {
        switch quality {
        case .hd1080: return 6_000_000
        case .uhd4K: return 13_000_000
        }
    }
}

/// Chooses the capture format that gives both outputs the best quality for the
/// least processing. Preference order, encoded as a score:
///   1. must reach the target frame rate and use an allowed pixel format;
///   2. avoid upscaling either output (heavy penalty proportional to the upscale);
///   3. prefer 4:3 sensors (the landscape crop gets a wider field of view);
///   4. among the rest, prefer fewer pixels (cooler, fewer dropped frames), and
///      penalise formats over the tier's pixel budget steeply;
///   5. small bonus for binned formats (better low light);
///   6. tiny bonus for full-range 4:2:0 to break ties between identical sizes.
public enum CaptureFormatSelector {

    public static func select(from candidates: [CaptureFormatCandidate],
                              requirements: CaptureFormatRequirements = CaptureFormatRequirements()) -> CaptureFormatCandidate? {
        let scored: [(CaptureFormatCandidate, Double)] = candidates.compactMap { candidate in
            guard let score = score(candidate, requirements: requirements) else { return nil }
            return (candidate, score)
        }
        return scored.max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            // Tie-break: fewer pixels first, then the earlier format.
            if lhs.0.sensorSize.pixelCount != rhs.0.sensorSize.pixelCount {
                return lhs.0.sensorSize.pixelCount > rhs.0.sensorSize.pixelCount
            }
            return lhs.0.index > rhs.0.index
        }?.0
    }

    /// Returns nil when the candidate is ineligible.
    public static func score(_ candidate: CaptureFormatCandidate,
                             requirements: CaptureFormatRequirements) -> Double? {
        guard candidate.width > 0, candidate.height > 0 else { return nil }
        guard candidate.maxFrameRate + 0.001 >= requirements.targetFrameRate else { return nil }
        guard requirements.allowedPixelFormats.contains(candidate.pixelFormat) else { return nil }
        guard candidate.sensorSize.longSide <= requirements.maxLongSide else { return nil }

        let plan = FramingPlanner.plan(sourceSize: requirements.uprightSize(of: candidate),
                                       pair: requirements.pair,
                                       quality: requirements.quality)
        var score = 0.0

        // 2. Upscale penalty.
        let upscale = max(0, plan.maxScaleFactor - 1)
        score -= upscale * 100

        // 3. Aspect preference: 4:3 (or 3:4 / square) first, then anything squarer than 16:9.
        let upright = requirements.uprightSize(of: candidate)
        let uprightAspect = upright.aspectValue
        if AspectRatio.landscape4x3.matches(candidate.sensorSize)
            || AspectRatio.portrait3x4.matches(upright)
            || AspectRatio.square.matches(upright) {
            score += 50
        } else if candidate.sensorSize.aspectValue < AspectRatio.landscape16x9.value - 0.01
                    && uprightAspect < AspectRatio.landscape16x9.value - 0.01 {
            score += 25
        }

        // 4. Pixel cost (megapixels * 2), plus a steep penalty over the soft budget.
        let megapixels = Double(candidate.sensorSize.pixelCount) / 1_000_000
        score -= megapixels * 2
        let excess = Double(candidate.sensorSize.pixelCount - requirements.softMaxPixels) / 1_000_000
        if excess > 0 { score -= excess * 12 }

        // 5. Binned bonus.
        if candidate.isBinned { score += 5 }

        // 6. Tie-break between otherwise identical formats: prefer full-range 4:2:0.
        if candidate.pixelFormat == "420f" { score += 0.5 }

        return score
    }
}
