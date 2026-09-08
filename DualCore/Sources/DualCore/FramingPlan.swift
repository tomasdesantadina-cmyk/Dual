import Foundation

/// One output stream: where to crop the upright source and what size to encode.
public struct FramingOutput: Hashable, Codable, Sendable, Identifiable {
    public let aspect: AspectRatio
    public let cropRect: PixelRect
    public let outputSize: PixelSize

    public init(aspect: AspectRatio, cropRect: PixelRect, outputSize: PixelSize) {
        self.aspect = aspect
        self.cropRect = cropRect
        self.outputSize = outputSize
    }

    public var id: String { aspect.label }

    /// > 1 means the crop is being upscaled to reach the output size.
    public var scaleFactor: Double { FramingGeometry.scaleFactor(from: cropRect.size, to: outputSize) }
    public var isUpscaled: Bool { scaleFactor > 1.0001 }
}

/// The complete plan for a pair of outputs from one upright source frame.
public struct FramingPlan: Hashable, Codable, Sendable {
    public let sourceSize: PixelSize
    public let outputs: [FramingOutput]

    public init(sourceSize: PixelSize, outputs: [FramingOutput]) {
        self.sourceSize = sourceSize
        self.outputs = outputs
    }

    public var primary: FramingOutput? { outputs.first }
    public var secondary: FramingOutput? { outputs.count > 1 ? outputs[1] : nil }

    /// The largest upscale factor across outputs (1.0 when nothing is upscaled).
    public var maxScaleFactor: Double { outputs.map(\.scaleFactor).max() ?? 0 }
}

public enum FramingPlanner {
    /// Builds crop rects and output sizes for `pair` from an upright source frame.
    public static func plan(sourceSize: PixelSize, pair: FormatPair, quality: VideoQuality) -> FramingPlan {
        let outputs = pair.aspects.map { aspect in
            FramingOutput(
                aspect: aspect,
                cropRect: FramingGeometry.centeredCrop(in: sourceSize, aspect: aspect),
                outputSize: quality.outputSize(for: aspect)
            )
        }
        return FramingPlan(sourceSize: sourceSize, outputs: outputs)
    }
}
