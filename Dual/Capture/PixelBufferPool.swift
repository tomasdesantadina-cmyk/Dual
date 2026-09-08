import CoreVideo
import Foundation

/// A small wrapper around CVPixelBufferPool for one fixed output size.
/// Buffers are BGRA and IOSurface-backed so Core Image, the video encoder and
/// the display layer can all share them without copies.
final class PixelBufferPool {
    let width: Int
    let height: Int
    private let pool: CVPixelBufferPool

    init?(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA, minimumBufferCount: Int = 4) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBufferCount,
        ]

        var createdPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttributes as CFDictionary,
                                             bufferAttributes as CFDictionary,
                                             &createdPool)
        guard status == kCVReturnSuccess, let createdPool else { return nil }
        pool = createdPool
    }

    /// Upper bound on live buffers from this pool. When a consumer stalls (encoder
    /// back-pressure) new frames are dropped instead of growing memory without limit.
    static let allocationThreshold = 8

    /// Vends a buffer from the pool, or nil if the pool hit its threshold or failed.
    func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let auxAttributes: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: PixelBufferPool.allocationThreshold,
        ]
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
                                                                         pool,
                                                                         auxAttributes as CFDictionary,
                                                                         &buffer)
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// Returns unused buffers to the system.
    func flush() {
        CVPixelBufferPoolFlush(pool, CVPixelBufferPoolFlushFlags(rawValue: 0))
    }
}
