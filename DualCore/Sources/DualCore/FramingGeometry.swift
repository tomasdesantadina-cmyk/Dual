import Foundation

/// Pure geometry for deriving output framings from an upright source frame.
public enum FramingGeometry {

    /// The largest rectangle with the requested aspect ratio that fits inside
    /// `source`, centred, snapped to even pixel dimensions and even offsets.
    ///
    /// `source` must be in the orientation the output should have (i.e. an
    /// upright, already-rotated frame). For a portrait 3:4 source this yields a
    /// full-height 9:16 crop and a full-width 16:9 crop, which is exactly what a
    /// dual-format recorder needs: the landscape output covers a wider
    /// horizontal field of view than the portrait one.
    public static func centeredCrop(in source: PixelSize, aspect: AspectRatio) -> PixelRect {
        guard !source.isEmpty else { return .zero }
        let sourceAspect = source.aspectValue
        let target = aspect.value

        var cropWidth: Int
        var cropHeight: Int
        if sourceAspect > target {
            // Source is wider than the target: keep full height, trim width.
            cropHeight = source.height - (source.height % 2)
            cropWidth = evenFloor(Double(cropHeight) * target)
        } else {
            // Source is taller (or equal): keep full width, trim height.
            cropWidth = source.width - (source.width % 2)
            cropHeight = evenFloor(Double(cropWidth) / target)
        }
        cropWidth = min(cropWidth, source.width)
        cropHeight = min(cropHeight, source.height)

        // Centre and snap the origin to even pixels so 4:2:0 chroma stays aligned.
        var originX = (source.width - cropWidth) / 2
        var originY = (source.height - cropHeight) / 2
        originX -= originX % 2
        originY -= originY % 2

        return PixelRect(x: originX, y: originY, width: cropWidth, height: cropHeight)
    }

    /// Scale factor needed to fill `output` from a crop of `crop` size.
    /// Values above 1 mean upscaling.
    public static func scaleFactor(from crop: PixelSize, to output: PixelSize) -> Double {
        guard !crop.isEmpty, !output.isEmpty else { return 0 }
        return max(Double(output.width) / Double(crop.width),
                   Double(output.height) / Double(crop.height))
    }
}
