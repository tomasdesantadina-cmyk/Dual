import Foundation

/// A display aspect ratio expressed as integer width:height.
public struct AspectRatio: Hashable, Codable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(_ width: Int, _ height: Int) {
        precondition(width > 0 && height > 0, "Aspect ratio components must be positive")
        self.width = width
        self.height = height
    }

    /// width / height
    public var value: Double { Double(width) / Double(height) }
    public var isPortrait: Bool { height > width }
    public var isLandscape: Bool { width > height }
    public var isSquare: Bool { width == height }

    /// Human label such as "9:16".
    public var label: String { "\(width):\(height)" }
    public var description: String { label }

    /// Same ratio with width and height swapped.
    public var rotated: AspectRatio { AspectRatio(height, width) }

    public static let portrait9x16 = AspectRatio(9, 16)
    public static let landscape16x9 = AspectRatio(16, 9)
    public static let square = AspectRatio(1, 1)
    public static let portrait4x5 = AspectRatio(4, 5)
    public static let portrait3x4 = AspectRatio(3, 4)
    public static let landscape4x3 = AspectRatio(4, 3)

    /// Whether two ratios are numerically equal within a small tolerance
    /// (e.g. 1920x1440 is 4:3 even though the integers differ).
    public func matches(_ other: AspectRatio, tolerance: Double = 0.01) -> Bool {
        abs(value - other.value) < tolerance
    }

    /// Whether a pixel size has (approximately) this aspect ratio.
    public func matches(_ size: PixelSize, tolerance: Double = 0.01) -> Bool {
        guard !size.isEmpty else { return false }
        return abs(size.aspectValue - value) < tolerance
    }
}
