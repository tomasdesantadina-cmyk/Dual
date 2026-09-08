import Foundation

/// Maps the device's raw videoZoomFactor to the "0.5x / 1x / 2x" numbers users
/// expect, mirroring how the system Camera app labels zoom on multi-lens phones.
public struct ZoomModel: Hashable, Sendable {
    /// device.minAvailableVideoZoomFactor
    public let minZoom: Double
    /// device.maxAvailableVideoZoomFactor, clamped by `maxDisplayFactor`.
    public let maxZoom: Double
    /// device.virtualDeviceSwitchOverVideoZoomFactors (empty for a physical camera).
    public let switchOverFactors: [Double]
    /// Whether the device includes an ultra-wide constituent camera.
    public let hasUltraWide: Bool

    /// Largest display factor we allow the user to reach. The system camera goes
    /// further, but beyond this the crop from even a 48 MP sensor is very soft.
    public static let maxDisplayFactor = 25.0

    public init(minZoom: Double, maxZoom: Double, switchOverFactors: [Double], hasUltraWide: Bool) {
        let safeMin = max(1.0, minZoom.isFinite ? minZoom : 1.0)
        self.minZoom = safeMin
        self.switchOverFactors = switchOverFactors.filter { $0.isFinite && $0 > 0 }.sorted()
        self.hasUltraWide = hasUltraWide
        let wide = hasUltraWide ? (self.switchOverFactors.first ?? 1.0) : 1.0
        let ceiling = wide * ZoomModel.maxDisplayFactor
        let safeMax = maxZoom.isFinite ? maxZoom : ceiling
        self.maxZoom = max(safeMin, min(safeMax, ceiling))
    }

    /// A single fixed lens with digital zoom only.
    public static let singleCamera = ZoomModel(minZoom: 1, maxZoom: 10, switchOverFactors: [], hasUltraWide: false)

    /// The raw zoom factor that corresponds to the "1x" wide camera.
    public var wideFactor: Double { hasUltraWide ? (switchOverFactors.first ?? 1.0) : 1.0 }

    /// Raw factor -> displayed factor (e.g. 2.0 -> 1.0 on an ultra-wide-equipped phone).
    public func displayFactor(for zoom: Double) -> Double { zoom / wideFactor }

    /// Displayed factor -> raw factor, clamped to the device range.
    public func zoom(forDisplayFactor factor: Double) -> Double { clamped(factor * wideFactor) }

    public func clamped(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return wideFactor }
        return min(maxZoom, max(minZoom, zoom))
    }

    /// Raw zoom for a pinch gesture that started at `startZoom`.
    public func zoom(forPinchScale scale: Double, startZoom: Double) -> Double {
        clamped(startZoom * (scale.isFinite && scale > 0 ? scale : 1))
    }

    /// Display factors for the zoom chip, mirroring the system camera: 0.5x (if
    /// ultra-wide), 1x, a 2x sensor crop, then each lens switch-over point (3x, 4x,
    /// 5x). A single-lens phone offers 1x and 2x.
    public var presets: [Double] {
        var result: [Double] = []
        if hasUltraWide {
            result.append(displayFactor(for: minZoom))
        }
        result.append(1.0)
        let lensFactors = switchOverFactors
            .map { displayFactor(for: $0) }
            .filter { $0 > 1.0 + 0.01 }
        let hasLensNearTwo = lensFactors.contains { abs($0 - 2.0) < 0.3 }
        if !hasLensNearTwo, displayFactor(for: maxZoom) >= 2.0 {
            result.append(2.0)
        }
        result.append(contentsOf: lensFactors.sorted())
        // Deduplicate (with rounding) while keeping order.
        var seen = Set<Int>()
        return result.filter { value in
            let key = Int((value * 100).rounded())
            return seen.insert(key).inserted
        }
    }

    /// The raw zoom of the preset following the current zoom, cycling around.
    public func nextPresetZoom(after zoom: Double) -> Double {
        let current = displayFactor(for: zoom)
        let list = presets
        guard !list.isEmpty else { return clamped(zoom) }
        if let next = list.first(where: { $0 > current + 0.05 }) {
            return self.zoom(forDisplayFactor: next)
        }
        return self.zoom(forDisplayFactor: list[0])
    }

    /// "0.5x", "1x", "2.1x", "3x".
    public static func label(forDisplayFactor factor: Double) -> String {
        guard factor.isFinite else { return "1x" }
        let rounded = (factor * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))x"
        }
        return String(format: "%.1fx", rounded)
    }

    public func label(forZoom zoom: Double) -> String {
        ZoomModel.label(forDisplayFactor: displayFactor(for: zoom))
    }
}
