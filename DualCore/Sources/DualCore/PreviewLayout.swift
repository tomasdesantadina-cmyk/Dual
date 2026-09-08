import Foundation

/// Sizes the stacked preview panes so both fit the available area: wide panes
/// (landscape or square) take the full width, tall panes take a fraction of it,
/// and everything is scaled down uniformly when the stack is too tall.
public struct PreviewLayout: Hashable, Sendable {

    public struct Pane: Hashable, Sendable, Identifiable {
        public let aspect: AspectRatio
        public let width: Double
        public let height: Double

        public var id: String { aspect.label }
    }

    public let panes: [Pane]
    public let spacing: Double

    public var totalHeight: Double {
        panes.map(\.height).reduce(0, +) + Double(max(0, panes.count - 1)) * spacing
    }

    /// Fraction of the available width a tall (portrait) pane is allowed to use.
    public static let tallPaneWidthFraction = 0.46

    public static func compute(availableWidth: Double,
                               availableHeight: Double,
                               aspects: [AspectRatio],
                               spacing: Double = 14) -> PreviewLayout {
        guard availableWidth > 0, availableHeight > 0, !aspects.isEmpty else {
            return PreviewLayout(panes: [], spacing: spacing)
        }

        var panes: [Pane] = aspects.map { aspect in
            let width = aspect.value >= 1 ? availableWidth : availableWidth * tallPaneWidthFraction
            return Pane(aspect: aspect, width: width, height: width / aspect.value)
        }

        let gaps = Double(max(0, panes.count - 1)) * spacing
        let naturalHeight = panes.map(\.height).reduce(0, +)
        let room = availableHeight - gaps
        if naturalHeight > room, naturalHeight > 0 {
            let scale = max(0, room / naturalHeight)
            panes = panes.map { Pane(aspect: $0.aspect, width: $0.width * scale, height: $0.height * scale) }
        }
        return PreviewLayout(panes: panes, spacing: spacing)
    }
}
