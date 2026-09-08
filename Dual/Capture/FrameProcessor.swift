import CoreImage
import CoreMedia
import CoreVideo
import DualCore
import Foundation
import ImageIO
import Metal

/// Turns one raw camera frame into N upright, filtered, cropped and scaled
/// output frames using Core Image on the GPU. Not thread-safe: call it from a
/// single serial queue (the capture data queue).
final class FrameProcessor {

    struct RenderedOutput {
        let framing: FramingOutput
        let pixelBuffer: CVPixelBuffer
    }

    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private var pools: [PixelSize: PixelBufferPool] = [:]
    private var filterCache: [String: CIFilter] = [:]

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .name: "com.intriq.dual.frameprocessor",
            ])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    // MARK: - Public

    /// Produces the upright, filtered source image for a raw camera buffer.
    /// The returned image always has its extent origin at (0, 0).
    func uprightImage(from pixelBuffer: CVPixelBuffer,
                      orientation: CGImagePropertyOrientation,
                      filter: VideoFilterPreset) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        image = normalizedToOrigin(image)
        if let filtered = apply(filter, to: image) {
            // Some filters report an infinite or padded extent; keep the frame size.
            image = normalizedToOrigin(filtered.cropped(to: image.extent))
        }
        return image
    }

    /// Renders each output of `plan` from the upright image into pooled buffers.
    /// Outputs that cannot be rendered are skipped, so callers should match by
    /// `framing` rather than by index.
    func render(upright image: CIImage, plan: FramingPlan) -> [RenderedOutput] {
        let uprightSize = PixelSize(width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()))
        var results: [RenderedOutput] = []
        results.reserveCapacity(plan.outputs.count)

        for output in plan.outputs {
            guard let buffer = pool(for: output.outputSize)?.makeBuffer() else { continue }
            let outputRect = CGRect(x: 0, y: 0, width: output.outputSize.width, height: output.outputSize.height)
            let cropped = crop(image, to: output.cropRect, uprightSize: uprightSize)
            // clampedToExtent repeats edge pixels so fractional scale factors never
            // leave a transparent row or column; the final crop pins the extent.
            let scaled = scale(cropped.clampedToExtent(), to: output.outputSize, referenceExtent: cropped.extent)
                .cropped(to: outputRect)
            context.render(scaled, to: buffer, bounds: outputRect, colorSpace: colorSpace)
            results.append(RenderedOutput(framing: output, pixelBuffer: buffer))
        }
        return results
    }

    /// JPEG data for a still image of the given Core Image image.
    func jpegData(for image: CIImage, quality: Double = 0.92) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        return context.jpegRepresentation(of: image, colorSpace: space, options: options)
    }

    /// Drops cached pools (e.g. when the output sizes change or on memory pressure).
    func resetPools() {
        pools.values.forEach { $0.flush() }
        pools.removeAll()
    }

    // MARK: - Private

    private func pool(for size: PixelSize) -> PixelBufferPool? {
        if let existing = pools[size] { return existing }
        guard let created = PixelBufferPool(width: size.width, height: size.height) else { return nil }
        pools[size] = created
        return created
    }

    /// Translates an image so its extent starts at (0, 0).
    private func normalizedToOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin.x != 0 || origin.y != 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// Crops using a top-left-origin pixel rect. Core Image uses a bottom-left
    /// origin, so the y coordinate is flipped against the upright frame height.
    private func crop(_ image: CIImage, to rect: PixelRect, uprightSize: PixelSize) -> CIImage {
        guard !rect.isEmpty else { return image }
        let ciRect = CGRect(x: CGFloat(rect.x),
                            y: CGFloat(uprightSize.height - rect.y - rect.height),
                            width: CGFloat(rect.width),
                            height: CGFloat(rect.height))
        return normalizedToOrigin(image.cropped(to: ciRect))
    }

    /// Scales so that `referenceExtent` (the finite crop extent) maps exactly onto
    /// `size`. The image itself may be infinite (clamped), so the reference is passed in.
    private func scale(_ image: CIImage, to size: PixelSize, referenceExtent: CGRect) -> CIImage {
        guard referenceExtent.width > 0, referenceExtent.height > 0, !size.isEmpty else { return image }
        let sx = CGFloat(size.width) / referenceExtent.width
        let sy = CGFloat(size.height) / referenceExtent.height
        if abs(sx - 1) < 0.0005 && abs(sy - 1) < 0.0005 { return image }
        return image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    private func apply(_ preset: VideoFilterPreset, to image: CIImage) -> CIImage? {
        guard let name = preset.ciFilterName else { return nil }
        let filter: CIFilter
        if let cached = filterCache[preset.id] {
            filter = cached
        } else {
            guard let created = CIFilter(name: name) else { return nil }
            filterCache[preset.id] = created
            filter = created
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in preset.parameters {
            filter.setValue(NSNumber(value: value), forKey: key)
        }
        let output = filter.outputImage
        // The output graph owns its copy of the input; clearing the filter's input
        // stops the cached filter from pinning the camera's pixel buffer.
        filter.setValue(nil, forKey: kCIInputImageKey)
        return output
    }
}
