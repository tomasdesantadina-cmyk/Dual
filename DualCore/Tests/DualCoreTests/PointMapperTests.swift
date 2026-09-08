import XCTest
@testable import DualCore

final class PointMapperTests: XCTestCase {

    let upright = PixelSize(width: 1944, height: 2592)

    func testPreviewPointInsideLandscapeCrop() {
        let crop = PixelRect(x: 0, y: 750, width: 1944, height: 1092)
        let centre = PointMapper.uprightPoint(fromPreviewPoint: UnitPoint2D(x: 0.5, y: 0.5), crop: crop, uprightSize: upright)
        XCTAssertEqual(centre.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(centre.y, (750 + 546) / 2592.0, accuracy: 0.001)
        let topLeft = PointMapper.uprightPoint(fromPreviewPoint: UnitPoint2D(x: 0, y: 0), crop: crop, uprightSize: upright)
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 750 / 2592.0, accuracy: 0.001)
    }

    func testPreviewPointInsidePortraitCrop() {
        let crop = PixelRect(x: 242, y: 0, width: 1458, height: 2592)
        let right = PointMapper.uprightPoint(fromPreviewPoint: UnitPoint2D(x: 1, y: 0.25), crop: crop, uprightSize: upright)
        XCTAssertEqual(right.x, 1700 / 1944.0, accuracy: 0.001)
        XCTAssertEqual(right.y, 0.25, accuracy: 0.001)
    }

    func testBackCameraDeviceMapping() {
        // Rotating the raw frame clockwise puts the raw top-right corner at the upright top-left.
        let tl = PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 0, y: 0), transform: .rotateClockwise)
        XCTAssertEqual(tl, UnitPoint2D(x: 0, y: 1))
        let tr = PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 1, y: 0), transform: .rotateClockwise)
        XCTAssertEqual(tr, UnitPoint2D(x: 0, y: 0))
        let centre = PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 0.5, y: 0.5), transform: .rotateClockwise)
        XCTAssertEqual(centre, UnitPoint2D(x: 0.5, y: 0.5))
        let bottomLeft = PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 0, y: 1), transform: .rotateClockwise)
        XCTAssertEqual(bottomLeft, UnitPoint2D(x: 1, y: 1))
    }

    func testFrontCameraMirroredMapping() {
        let tl = PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 0, y: 0), transform: .rotateClockwiseMirrored)
        XCTAssertEqual(tl, UnitPoint2D(x: 0, y: 0))
        let br = PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 1, y: 1), transform: .rotateClockwiseMirrored)
        XCTAssertEqual(br, UnitPoint2D(x: 1, y: 1))
        let tr = PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 1, y: 0), transform: .rotateClockwiseMirrored)
        XCTAssertEqual(tr, UnitPoint2D(x: 0, y: 1))
    }

    func testOtherRotations() {
        let none = UprightTransform(rotationDegrees: 0, mirrored: false)
        XCTAssertEqual(PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 0.2, y: 0.7), transform: none), UnitPoint2D(x: 0.2, y: 0.7))

        let half = UprightTransform(rotationDegrees: 180, mirrored: false)
        XCTAssertEqual(PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 0, y: 0), transform: half), UnitPoint2D(x: 1, y: 1))

        // Counter-clockwise: raw top-right corner lands at the upright top-left... after CCW rotation the
        // raw top-left goes to the upright bottom-left, so upright top-left comes from raw top-right.
        let ccw = UprightTransform(rotationDegrees: 270, mirrored: false)
        XCTAssertEqual(PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 0, y: 0), transform: ccw), UnitPoint2D(x: 1, y: 0))
        XCTAssertEqual(PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 0, y: 1), transform: ccw), UnitPoint2D(x: 0, y: 0))

        let mirroredNone = UprightTransform(rotationDegrees: 0, mirrored: true)
        XCTAssertEqual(PointMapper.devicePoint(fromUprightPoint: UnitPoint2D(x: 0, y: 0), transform: mirroredNone), UnitPoint2D(x: 1, y: 0))
    }

    func testRoundTripThroughEveryTransform() {
        // Forward mapping raw -> upright for each rotation, used to verify the inverse.
        func forward(_ raw: UnitPoint2D, _ t: UprightTransform) -> UnitPoint2D {
            var p: UnitPoint2D
            switch t.rotationDegrees {
            case 90: p = UnitPoint2D(x: 1 - raw.y, y: raw.x)
            case 180: p = UnitPoint2D(x: 1 - raw.x, y: 1 - raw.y)
            case 270: p = UnitPoint2D(x: raw.y, y: 1 - raw.x)
            default: p = raw
            }
            if t.mirrored { p = UnitPoint2D(x: 1 - p.x, y: p.y) }
            return p
        }
        let raw = UnitPoint2D(x: 0.3, y: 0.8)
        for degrees in [0, 90, 180, 270] {
            for mirrored in [false, true] {
                let t = UprightTransform(rotationDegrees: degrees, mirrored: mirrored)
                let back = PointMapper.devicePoint(fromUprightPoint: forward(raw, t), transform: t)
                XCTAssertEqual(back.x, raw.x, accuracy: 1e-9, "\(t)")
                XCTAssertEqual(back.y, raw.y, accuracy: 1e-9, "\(t)")
            }
        }
    }

    func testTransformNormalisation() {
        XCTAssertEqual(UprightTransform(rotationDegrees: 450, mirrored: false).rotationDegrees, 90)
        XCTAssertEqual(UprightTransform(rotationDegrees: -90, mirrored: false).rotationDegrees, 270)
        XCTAssertEqual(UprightTransform(rotationDegrees: 89, mirrored: false).rotationDegrees, 90)
        XCTAssertEqual(UprightTransform.normalize(269.6), 270)
        XCTAssertEqual(UprightTransform.normalize(Double.nan), 90)
        XCTAssertTrue(UprightTransform.rotateClockwise.swapsDimensions)
        XCTAssertFalse(UprightTransform(rotationDegrees: 180, mirrored: true).swapsDimensions)
    }

    func testCombinedMappingStaysInUnitSquare() {
        let crop = PixelRect(x: 0, y: 750, width: 1944, height: 1092)
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.3, 0.9), (2.0, -1.0)] {
            let p = PointMapper.devicePoint(fromPreviewPoint: UnitPoint2D(x: x, y: y), crop: crop, uprightSize: upright, transform: .rotateClockwise)
            XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y))
        }
    }

    func testUnitPointClampsInput() {
        let p = UnitPoint2D(x: -3, y: .nan)
        XCTAssertEqual(p.x, 0)
        XCTAssertEqual(p.y, 0)
    }
}
