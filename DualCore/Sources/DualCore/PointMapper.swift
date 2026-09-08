import Foundation

/// How the raw sensor frame is turned upright for the (portrait-locked) UI:
/// a clockwise rotation in degrees, optionally followed by a horizontal mirror.
/// The rotation normally comes from AVCaptureDevice.RotationCoordinator so the
/// app keeps working on devices whose sensors are mounted differently.
public struct UprightTransform: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Clockwise rotation applied to the raw frame: 0, 90, 180 or 270.
    public let rotationDegrees: Int
    /// Mirror horizontally after rotating (selfie-style front camera).
    public let mirrored: Bool

    public init(rotationDegrees: Int, mirrored: Bool) {
        self.rotationDegrees = UprightTransform.normalize(rotationDegrees)
        self.mirrored = mirrored
    }

    /// Snaps any angle (degrees, may be negative or >= 360) to the nearest
    /// multiple of 90 in 0..<360.
    public static func normalize(_ degrees: Int) -> Int {
        var value = degrees % 360
        if value < 0 { value += 360 }
        return ((value + 45) / 90 * 90) % 360
    }

    public static func normalize(_ degrees: Double) -> Int {
        guard degrees.isFinite else { return 90 }
        return normalize(Int(degrees.rounded()))
    }

    /// Back camera held in portrait on iPhones up to the 16 family.
    public static let rotateClockwise = UprightTransform(rotationDegrees: 90, mirrored: false)
    /// Front camera held in portrait, mirrored, on iPhones up to the 16 family.
    public static let rotateClockwiseMirrored = UprightTransform(rotationDegrees: 90, mirrored: true)

    /// Whether the upright frame has swapped width and height relative to the raw frame.
    public var swapsDimensions: Bool { rotationDegrees == 90 || rotationDegrees == 270 }

    public var description: String { "\(rotationDegrees)°\(mirrored ? " mirrored" : "")" }
}

/// A point with components in 0...1.
public struct UnitPoint2D: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(1, max(0, x.isFinite ? x : 0))
        self.y = min(1, max(0, y.isFinite ? y : 0))
    }
}

/// Converts taps on a cropped preview into camera focus/exposure coordinates.
public enum PointMapper {

    /// Maps a normalised tap inside a preview showing `crop` of an upright frame
    /// of `uprightSize` to a normalised point in the upright frame.
    public static func uprightPoint(fromPreviewPoint preview: UnitPoint2D,
                                    crop: PixelRect,
                                    uprightSize: PixelSize) -> UnitPoint2D {
        guard !crop.isEmpty, !uprightSize.isEmpty else { return preview }
        let x = (Double(crop.x) + preview.x * Double(crop.width)) / Double(uprightSize.width)
        let y = (Double(crop.y) + preview.y * Double(crop.height)) / Double(uprightSize.height)
        return UnitPoint2D(x: x, y: y)
    }

    /// Maps a normalised point in the upright frame back to the raw sensor frame,
    /// which is the coordinate system used by focusPointOfInterest and
    /// exposurePointOfInterest: (0,0) top-left, (1,1) bottom-right of the raw buffer.
    public static func devicePoint(fromUprightPoint upright: UnitPoint2D,
                                   transform: UprightTransform) -> UnitPoint2D {
        // Undo the mirror first (it is applied last when going raw -> upright).
        let x = transform.mirrored ? 1 - upright.x : upright.x
        let y = upright.y
        switch transform.rotationDegrees {
        case 90:
            // upright (x, y) = (1 - rawY, rawX)  =>  raw = (y, 1 - x)
            return UnitPoint2D(x: y, y: 1 - x)
        case 180:
            // upright (x, y) = (1 - rawX, 1 - rawY)
            return UnitPoint2D(x: 1 - x, y: 1 - y)
        case 270:
            // upright (x, y) = (rawY, 1 - rawX)  =>  raw = (1 - y, x)
            return UnitPoint2D(x: 1 - y, y: x)
        default:
            return UnitPoint2D(x: x, y: y)
        }
    }

    /// Convenience: preview tap -> device point of interest in one step.
    public static func devicePoint(fromPreviewPoint preview: UnitPoint2D,
                                   crop: PixelRect,
                                   uprightSize: PixelSize,
                                   transform: UprightTransform) -> UnitPoint2D {
        let upright = uprightPoint(fromPreviewPoint: preview, crop: crop, uprightSize: uprightSize)
        return devicePoint(fromUprightPoint: upright, transform: transform)
    }
}
