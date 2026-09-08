import XCTest
@testable import DualCore

final class FramingGeometryTests: XCTestCase {

    /// 2592x1944 sensor held upright.
    let portraitSource = PixelSize(width: 1944, height: 2592)

    func testPortraitCropUsesFullHeightOfFourByThreeSource() {
        let rect = FramingGeometry.centeredCrop(in: portraitSource, aspect: .portrait9x16)
        XCTAssertEqual(rect, PixelRect(x: 242, y: 0, width: 1458, height: 2592))
        XCTAssertTrue(rect.fits(in: portraitSource))
        XCTAssertEqual(Double(rect.width) / Double(rect.height), 9.0 / 16.0, accuracy: 0.002)
    }

    func testLandscapeCropUsesFullWidthOfFourByThreeSource() {
        let rect = FramingGeometry.centeredCrop(in: portraitSource, aspect: .landscape16x9)
        XCTAssertEqual(rect, PixelRect(x: 0, y: 750, width: 1944, height: 1092))
        XCTAssertTrue(rect.fits(in: portraitSource))
        XCTAssertEqual(Double(rect.width) / Double(rect.height), 16.0 / 9.0, accuracy: 0.005)
    }

    func testLandscapeSeesWiderHorizontalFieldThanPortrait() {
        let portrait = FramingGeometry.centeredCrop(in: portraitSource, aspect: .portrait9x16)
        let landscape = FramingGeometry.centeredCrop(in: portraitSource, aspect: .landscape16x9)
        XCTAssertGreaterThan(landscape.width, portrait.width)
        XCTAssertLessThan(landscape.height, portrait.height)
    }

    func testSquareCrop() {
        let rect = FramingGeometry.centeredCrop(in: portraitSource, aspect: .square)
        XCTAssertEqual(rect, PixelRect(x: 0, y: 324, width: 1944, height: 1944))
    }

    func testCropOfMatchingAspectIsTheWholeFrame() {
        let source = PixelSize(width: 2160, height: 3840)
        let rect = FramingGeometry.centeredCrop(in: source, aspect: .portrait9x16)
        XCTAssertEqual(rect, PixelRect(x: 0, y: 0, width: 2160, height: 3840))
    }

    func testLandscapeCropFromSixteenByNineSource() {
        let source = PixelSize(width: 2160, height: 3840)
        let rect = FramingGeometry.centeredCrop(in: source, aspect: .landscape16x9)
        XCTAssertEqual(rect, PixelRect(x: 0, y: 1312, width: 2160, height: 1214))
        XCTAssertTrue(rect.fits(in: source))
    }

    func testOddSourceDimensionsSnapToEvenValues() {
        let source = PixelSize(width: 1001, height: 1501)
        let rect = FramingGeometry.centeredCrop(in: source, aspect: .portrait9x16)
        XCTAssertEqual(rect.width % 2, 0)
        XCTAssertEqual(rect.height % 2, 0)
        XCTAssertEqual(rect.x % 2, 0)
        XCTAssertEqual(rect.y % 2, 0)
        XCTAssertTrue(rect.fits(in: source))
        XCTAssertEqual(rect, PixelRect(x: 78, y: 0, width: 842, height: 1500))
    }

    func testEmptySourceGivesZeroRect() {
        XCTAssertEqual(FramingGeometry.centeredCrop(in: .zero, aspect: .portrait9x16), .zero)
        XCTAssertEqual(FramingGeometry.centeredCrop(in: PixelSize(width: 100, height: 0), aspect: .square), .zero)
    }

    func testLandscapeSourceWorksToo() {
        let source = PixelSize(width: 1920, height: 1080)
        let portrait = FramingGeometry.centeredCrop(in: source, aspect: .portrait9x16)
        XCTAssertEqual(portrait, PixelRect(x: 656, y: 0, width: 606, height: 1080))
        let landscape = FramingGeometry.centeredCrop(in: source, aspect: .landscape16x9)
        XCTAssertEqual(landscape, PixelRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testScaleFactor() {
        XCTAssertEqual(FramingGeometry.scaleFactor(from: PixelSize(width: 1440, height: 810), to: PixelSize(width: 1920, height: 1080)), 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(FramingGeometry.scaleFactor(from: PixelSize(width: 1944, height: 1092), to: PixelSize(width: 1920, height: 1080)), 1080.0 / 1092.0, accuracy: 0.0001)
        XCTAssertEqual(FramingGeometry.scaleFactor(from: .zero, to: PixelSize(width: 10, height: 10)), 0)
    }

    func testEvenRounding() {
        XCTAssertEqual(evenFloor(1093.5), 1092)
        XCTAssertEqual(evenFloor(1458.0), 1458)
        XCTAssertEqual(evenFloor(7.9), 6)
        XCTAssertEqual(evenFloor(-3), 0)
        XCTAssertEqual(evenFloor(.nan), 0)
        XCTAssertEqual(evenRound(1349.99), 1350)
        XCTAssertEqual(evenRound(1919.0), 1920)
        XCTAssertEqual(evenRound(0.4), 0)
    }
}
