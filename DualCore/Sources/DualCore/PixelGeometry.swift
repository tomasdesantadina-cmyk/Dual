import Foundation

/// Integer pixel dimensions. Used instead of CGSize so the geometry stays
/// platform-neutral, integer-exact and trivially Hashable/Codable.
public struct PixelSize: Hashable, Codable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = PixelSize(width: 0, height: 0)

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var pixelCount: Int { max(0, width) * max(0, height) }
    public var aspectValue: Double { height == 0 ? 0 : Double(width) / Double(height) }
    public var isPortrait: Bool { height > width }
    public var longSide: Int { max(width, height) }
    public var shortSide: Int { min(width, height) }

    /// The same frame rotated by 90 degrees.
    public var rotated: PixelSize { PixelSize(width: height, height: width) }

    public var description: String { "\(width)x\(height)" }
}

/// Integer pixel rectangle with a top-left origin (image coordinates).
public struct PixelRect: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    public var size: PixelSize { PixelSize(width: width, height: height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    /// True when the rectangle lies fully inside a frame of the given size.
    public func fits(in frame: PixelSize) -> Bool {
        x >= 0 && y >= 0 && maxX <= frame.width && maxY <= frame.height
    }

    public var description: String { "(\(x), \(y), \(width)x\(height))" }
}

/// Rounds down to the nearest even, non-negative integer.
/// Video encoders and 4:2:0 chroma subsampling want even dimensions and offsets.
@inlinable
public func evenFloor(_ value: Double) -> Int {
    guard value.isFinite, value > 0 else { return 0 }
    let floored = Int(value.rounded(.down))
    return floored - (floored % 2)
}

/// Rounds to the nearest even, non-negative integer.
@inlinable
public func evenRound(_ value: Double) -> Int {
    guard value.isFinite, value > 0 else { return 0 }
    let rounded = Int((value / 2).rounded()) * 2
    return max(0, rounded)
}
