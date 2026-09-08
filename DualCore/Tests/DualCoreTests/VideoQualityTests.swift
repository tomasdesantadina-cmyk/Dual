import XCTest
@testable import DualCore

final class VideoQualityTests: XCTestCase {

    func testHDOutputSizes() {
        XCTAssertEqual(VideoQuality.hd1080.outputSize(for: .portrait9x16), PixelSize(width: 1080, height: 1920))
        XCTAssertEqual(VideoQuality.hd1080.outputSize(for: .landscape16x9), PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(VideoQuality.hd1080.outputSize(for: .square), PixelSize(width: 1080, height: 1080))
        XCTAssertEqual(VideoQuality.hd1080.outputSize(for: .portrait4x5), PixelSize(width: 1080, height: 1350))
    }

    func testUHDOutputSizes() {
        XCTAssertEqual(VideoQuality.uhd4K.outputSize(for: .portrait9x16), PixelSize(width: 2160, height: 3840))
        XCTAssertEqual(VideoQuality.uhd4K.outputSize(for: .landscape16x9), PixelSize(width: 3840, height: 2160))
    }

    func testOutputSizesAreEven() {
        for quality in VideoQuality.allCases {
            for pair in FormatPair.presets {
                for aspect in pair.aspects {
                    let size = quality.outputSize(for: aspect)
                    XCTAssertEqual(size.width % 2, 0, "\(quality) \(aspect)")
                    XCTAssertEqual(size.height % 2, 0, "\(quality) \(aspect)")
                }
            }
        }
    }

    func testBitratePlanning() {
        let hd = PixelSize(width: 1920, height: 1080)
        XCTAssertEqual(VideoEncodingPlan.averageBitrate(for: hd, frameRate: 30, codec: .h264), 9_953_280)
        XCTAssertEqual(VideoEncodingPlan.averageBitrate(for: hd, frameRate: 30, codec: .hevc), 7_464_960)
        XCTAssertEqual(VideoEncodingPlan.averageBitrate(for: PixelSize(width: 3840, height: 2160), frameRate: 30, codec: .hevc), 29_859_840)
        XCTAssertLessThan(VideoEncodingPlan.averageBitrate(for: hd, frameRate: 30, codec: .hevc),
                          VideoEncodingPlan.averageBitrate(for: hd, frameRate: 30, codec: .h264))
        XCTAssertEqual(VideoEncodingPlan.averageBitrate(for: PixelSize(width: 16, height: 16), frameRate: 30, codec: .h264), VideoEncodingPlan.minimumBitrate)
        XCTAssertEqual(VideoEncodingPlan.averageBitrate(for: PixelSize(width: 8000, height: 8000), frameRate: 120, codec: .h264), VideoEncodingPlan.maximumBitrate)
        XCTAssertEqual(VideoEncodingPlan.averageBitrate(for: .zero, frameRate: 30, codec: .h264), VideoEncodingPlan.minimumBitrate)
    }
}
