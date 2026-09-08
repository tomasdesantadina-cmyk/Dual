import Foundation

/// The two framings recorded simultaneously.
public struct FormatPair: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    /// The framing shown on top / recorded first (usually portrait).
    public let primary: AspectRatio
    /// The framing shown below / recorded second (usually landscape).
    public let secondary: AspectRatio

    public init(primary: AspectRatio, secondary: AspectRatio) {
        self.primary = primary
        self.secondary = secondary
    }

    public var id: String { "\(primary.label)|\(secondary.label)" }

    /// Label as shown in the UI chip, e.g. "9:16 x 16:9".
    public var label: String { "\(primary.label) x \(secondary.label)" }
    public var description: String { label }

    public var aspects: [AspectRatio] { [primary, secondary] }

    public static let portraitAndLandscape = FormatPair(primary: .portrait9x16, secondary: .landscape16x9)
    public static let squareAndLandscape = FormatPair(primary: .square, secondary: .landscape16x9)
    public static let tallAndLandscape = FormatPair(primary: .portrait4x5, secondary: .landscape16x9)
    public static let portraitAndSquare = FormatPair(primary: .portrait9x16, secondary: .square)

    /// Pairs offered by the format chip, in display order.
    public static let presets: [FormatPair] = [
        .portraitAndLandscape,
        .squareAndLandscape,
        .tallAndLandscape,
        .portraitAndSquare,
    ]

    /// The preset following `self` in `presets`, wrapping around.
    public var nextPreset: FormatPair {
        guard let index = FormatPair.presets.firstIndex(of: self) else { return FormatPair.presets[0] }
        return FormatPair.presets[(index + 1) % FormatPair.presets.count]
    }
}
