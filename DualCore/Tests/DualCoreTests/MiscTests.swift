import XCTest
@testable import DualCore

final class RecordingClockTests: XCTestCase {
    func testTimecode() {
        XCTAssertEqual(RecordingClock.timecode(seconds: 0), "00:00:00")
        XCTAssertEqual(RecordingClock.timecode(seconds: 36.7), "00:00:36")
        XCTAssertEqual(RecordingClock.timecode(seconds: 3661), "01:01:01")
        XCTAssertEqual(RecordingClock.timecode(seconds: -5), "00:00:00")
        XCTAssertEqual(RecordingClock.timecode(seconds: .nan), "00:00:00")
    }
}

final class FormatPairTests: XCTestCase {
    func testLabelsAndIDs() {
        XCTAssertEqual(FormatPair.portraitAndLandscape.label, "9:16 x 16:9")
        XCTAssertEqual(Set(FormatPair.presets.map(\.id)).count, FormatPair.presets.count)
    }

    func testCycling() {
        var pair = FormatPair.presets[0]
        for _ in 0..<FormatPair.presets.count { pair = pair.nextPreset }
        XCTAssertEqual(pair, FormatPair.presets[0])
        let unknown = FormatPair(primary: .portrait3x4, secondary: .square)
        XCTAssertEqual(unknown.nextPreset, FormatPair.presets[0])
    }
}

final class VideoFilterPresetTests: XCTestCase {
    func testPresets() {
        XCTAssertEqual(Set(VideoFilterPreset.all.map(\.id)).count, VideoFilterPreset.all.count)
        XCTAssertEqual(VideoFilterPreset.all.first, .passthrough)
        XCTAssertTrue(VideoFilterPreset.passthrough.isIdentity)
        XCTAssertEqual(VideoFilterPreset.preset(withID: "bogus"), .passthrough)
        XCTAssertEqual(VideoFilterPreset.preset(withID: "noir").ciFilterName, "CIPhotoEffectNoir")
        XCTAssertEqual(VideoFilterPreset.vivid.parameters["inputAmount"], 0.8)
    }
}

final class CaptureSettingsTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let settings = CaptureSettings.default
        XCTAssertEqual(settings.quality, .hd1080)
        XCTAssertEqual(settings.frameRate, 30)
        XCTAssertEqual(settings.pair, .portraitAndLandscape)
        XCTAssertTrue(settings.filter.isIdentity)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(CaptureSettings.self, from: data), settings)
    }

    func testSanitizeRepairsBadValues() {
        var settings = CaptureSettings.default
        settings.frameRate = 17
        settings.filterID = "nope"
        settings.pair = FormatPair(primary: .portrait3x4, secondary: .portrait3x4)
        let fixed = settings.sanitized()
        XCTAssertEqual(fixed.frameRate, 30)
        XCTAssertEqual(fixed.filterID, "none")
        XCTAssertEqual(fixed.pair, .portraitAndLandscape)
    }

    func testBitrateFollowsAspectAndCodec() {
        let settings = CaptureSettings.default
        XCTAssertEqual(settings.codec, .hevc)
        XCTAssertEqual(settings.bitrate(for: .portrait9x16), settings.bitrate(for: .landscape16x9))
        var h264 = settings
        h264.codec = .h264
        XCTAssertGreaterThan(h264.bitrate(for: .portrait9x16), settings.bitrate(for: .portrait9x16))
    }

    func testFormatRequirementsMirrorSettings() {
        var settings = CaptureSettings.default
        settings.frameRate = 60
        settings.quality = .uhd4K
        let req = settings.formatRequirements
        XCTAssertEqual(req.targetFrameRate, 60)
        XCTAssertEqual(req.quality, .uhd4K)
    }
}
