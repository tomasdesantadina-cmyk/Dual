import XCTest
@testable import DualCore

final class CaptureFormatSelectorTests: XCTestCase {

    /// A realistic wide-camera format list (roughly an iPhone 13 Pro).
    let iphoneFormats: [CaptureFormatCandidate] = [
        CaptureFormatCandidate(index: 0, width: 192, height: 144, maxFrameRate: 60, isBinned: true, pixelFormat: "420v"),
        CaptureFormatCandidate(index: 1, width: 1280, height: 720, maxFrameRate: 60, isBinned: true, pixelFormat: "420v"),
        CaptureFormatCandidate(index: 2, width: 1920, height: 1080, maxFrameRate: 60, isBinned: false, pixelFormat: "420v"),
        CaptureFormatCandidate(index: 3, width: 1920, height: 1080, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
        CaptureFormatCandidate(index: 4, width: 1920, height: 1080, maxFrameRate: 240, isBinned: true, pixelFormat: "420v"),
        CaptureFormatCandidate(index: 5, width: 1920, height: 1440, maxFrameRate: 60, isBinned: false, pixelFormat: "420v"),
        CaptureFormatCandidate(index: 6, width: 1920, height: 1440, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
        CaptureFormatCandidate(index: 7, width: 2592, height: 1944, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
        CaptureFormatCandidate(index: 8, width: 3264, height: 2448, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
        CaptureFormatCandidate(index: 9, width: 3840, height: 2160, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
        CaptureFormatCandidate(index: 10, width: 3840, height: 2160, maxFrameRate: 60, isBinned: false, pixelFormat: "420v"),
        CaptureFormatCandidate(index: 11, width: 3840, height: 2160, maxFrameRate: 30, isBinned: false, pixelFormat: "x420"),
        CaptureFormatCandidate(index: 12, width: 4032, height: 3024, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
    ]

    func testPicksSmallestFourByThreeFormatThatAvoidsUpscalingAt1080p30() {
        let chosen = CaptureFormatSelector.select(from: iphoneFormats, requirements: CaptureFormatRequirements(targetFrameRate: 30, quality: .hd1080))
        XCTAssertEqual(chosen?.index, 7, "expected 2592x1944, got \(String(describing: chosen))")
    }

    func testPrefersFourByThreeWithMildUpscaleOverHeavy4KAt60fps() {
        let chosen = CaptureFormatSelector.select(from: iphoneFormats, requirements: CaptureFormatRequirements(targetFrameRate: 60, quality: .hd1080))
        XCTAssertEqual(chosen?.index, 5, "expected 1920x1440@60, got \(String(describing: chosen))")
    }

    func testPicksTwelveMegapixelFormatFor4K() {
        let chosen = CaptureFormatSelector.select(from: iphoneFormats, requirements: CaptureFormatRequirements(targetFrameRate: 30, quality: .uhd4K))
        XCTAssertEqual(chosen?.index, 12, "expected 4032x3024, got \(String(describing: chosen))")
    }

    func testMaxLongSideExcludesLargeFormats() {
        let chosen = CaptureFormatSelector.select(from: iphoneFormats, requirements: CaptureFormatRequirements(targetFrameRate: 30, quality: .uhd4K, maxLongSide: 4000))
        XCTAssertNotEqual(chosen?.index, 12)
        XCTAssertNotNil(chosen)
    }

    func testTenBitFormatsAreIneligible() {
        let only10Bit = iphoneFormats.filter { $0.pixelFormat == "x420" }
        XCTAssertNil(CaptureFormatSelector.select(from: only10Bit))
    }

    func testUnreachableFrameRateGivesNil() {
        XCTAssertNil(CaptureFormatSelector.select(from: iphoneFormats, requirements: CaptureFormatRequirements(targetFrameRate: 480)))
    }

    func testFallsBackToUpscalingWhenNothingBetterExists() {
        let small = [
            CaptureFormatCandidate(index: 0, width: 1280, height: 720, maxFrameRate: 30, isBinned: false, pixelFormat: "420v"),
            CaptureFormatCandidate(index: 1, width: 1920, height: 1080, maxFrameRate: 30, isBinned: false, pixelFormat: "420v"),
        ]
        let chosen = CaptureFormatSelector.select(from: small)
        XCTAssertEqual(chosen?.index, 1)
    }

    func testTieBreakPrefersEarlierIndex() {
        let twins = [
            CaptureFormatCandidate(index: 3, width: 2592, height: 1944, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
            CaptureFormatCandidate(index: 1, width: 2592, height: 1944, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
        ]
        XCTAssertEqual(CaptureFormatSelector.select(from: twins)?.index, 1)
    }

    func testNeverStreamsTwelveMegapixelsFor1080pWhenSmallerExists() {
        let sparse = [
            CaptureFormatCandidate(index: 0, width: 1920, height: 1440, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
            CaptureFormatCandidate(index: 1, width: 4032, height: 3024, maxFrameRate: 30, isBinned: false, pixelFormat: "420f"),
        ]
        let chosen = CaptureFormatSelector.select(from: sparse, requirements: CaptureFormatRequirements(targetFrameRate: 30, quality: .hd1080))
        XCTAssertEqual(chosen?.index, 0, "1080p should accept a mild upscale over a 12 MP stream")
        let chosen4K = CaptureFormatSelector.select(from: sparse, requirements: CaptureFormatRequirements(targetFrameRate: 30, quality: .uhd4K))
        XCTAssertEqual(chosen4K?.index, 1)
    }

    func testWithoutFiveMegapixelFormat1080pPicksLightFormat() {
        let withoutFiveMP = iphoneFormats.filter { $0.index != 7 }
        let chosen = CaptureFormatSelector.select(from: withoutFiveMP, requirements: CaptureFormatRequirements(targetFrameRate: 30, quality: .hd1080))
        XCTAssertEqual(chosen?.index, 6, "expected 1920x1440@30 over the 8 MP 3264x2448, got \(String(describing: chosen))")
    }

    func testDefaultPixelBudgets() {
        XCTAssertEqual(CaptureFormatRequirements(quality: .hd1080).softMaxPixels, 6_000_000)
        XCTAssertEqual(CaptureFormatRequirements(quality: .uhd4K).softMaxPixels, 13_000_000)
        XCTAssertEqual(CaptureFormatRequirements(softMaxPixels: 1).softMaxPixels, 1)
    }

    func testPortraitMountedSquareSensorIsPlannedWithoutSwapping() {
        // iPhone 17 front camera: square sensor mounted in portrait, reported as 3024x3024,
        // upright rotation 0 degrees. Both crops should be full-width / full-height, no upscale.
        let square = CaptureFormatCandidate(index: 0, width: 3024, height: 3024, maxFrameRate: 30, isBinned: false, pixelFormat: "420f")
        var requirements = CaptureFormatRequirements(targetFrameRate: 30, quality: .hd1080)
        requirements.uprightSwapsDimensions = false
        XCTAssertEqual(requirements.uprightSize(of: square), PixelSize(width: 3024, height: 3024))
        let plan = FramingPlanner.plan(sourceSize: requirements.uprightSize(of: square), pair: .portraitAndLandscape, quality: .hd1080)
        XCTAssertLessThanOrEqual(plan.maxScaleFactor, 1)
        XCTAssertNotNil(CaptureFormatSelector.score(square, requirements: requirements))

        // A portrait-mounted 3:4 sensor reported as 3024x4032 with rotation 0.
        let tall = CaptureFormatCandidate(index: 1, width: 3024, height: 4032, maxFrameRate: 30, isBinned: false, pixelFormat: "420f")
        XCTAssertEqual(requirements.uprightSize(of: tall), PixelSize(width: 3024, height: 4032))
        let tallScore = CaptureFormatSelector.score(tall, requirements: requirements) ?? -1000
        var swapped = requirements
        swapped.uprightSwapsDimensions = true
        let swappedScore = CaptureFormatSelector.score(tall, requirements: swapped) ?? -1000
        XCTAssertGreaterThan(tallScore, swappedScore, "treating a portrait sensor as landscape would wrongly penalise it")
    }

    func testEmptyListGivesNil() {
        XCTAssertNil(CaptureFormatSelector.select(from: []))
    }

    func testScoreRejectsDegenerateFormats() {
        let bad = CaptureFormatCandidate(index: 0, width: 0, height: 0, maxFrameRate: 30, isBinned: false, pixelFormat: "420v")
        XCTAssertNil(CaptureFormatSelector.score(bad, requirements: CaptureFormatRequirements()))
    }
}
