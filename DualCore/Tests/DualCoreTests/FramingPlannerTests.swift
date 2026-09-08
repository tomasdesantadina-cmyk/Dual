import XCTest
@testable import DualCore

final class FramingPlannerTests: XCTestCase {

    func testPlanForFiveMegapixelSensorNeedsNoUpscale() {
        let plan = FramingPlanner.plan(sourceSize: PixelSize(width: 1944, height: 2592), pair: .portraitAndLandscape, quality: .hd1080)
        XCTAssertEqual(plan.outputs.count, 2)
        let primary = plan.primary!
        let secondary = plan.secondary!
        XCTAssertEqual(primary.aspect, .portrait9x16)
        XCTAssertEqual(primary.outputSize, PixelSize(width: 1080, height: 1920))
        XCTAssertEqual(primary.cropRect, PixelRect(x: 242, y: 0, width: 1458, height: 2592))
        XCTAssertFalse(primary.isUpscaled)
        XCTAssertEqual(secondary.aspect, .landscape16x9)
        XCTAssertEqual(secondary.outputSize, PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(secondary.cropRect, PixelRect(x: 0, y: 750, width: 1944, height: 1092))
        XCTAssertFalse(secondary.isUpscaled)
        XCTAssertLessThan(plan.maxScaleFactor, 1.0)
    }

    func testPlanForSmallSensorUpscalesLandscape() {
        let plan = FramingPlanner.plan(sourceSize: PixelSize(width: 1440, height: 1920), pair: .portraitAndLandscape, quality: .hd1080)
        XCTAssertFalse(plan.primary!.isUpscaled)
        XCTAssertTrue(plan.secondary!.isUpscaled)
        XCTAssertEqual(plan.maxScaleFactor, 4.0 / 3.0, accuracy: 0.001)
    }

    func testPlanIsCodable() throws {
        let plan = FramingPlanner.plan(sourceSize: PixelSize(width: 1944, height: 2592), pair: .squareAndLandscape, quality: .uhd4K)
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(FramingPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }

    func testOutputIDsFollowAspectLabels() {
        let plan = FramingPlanner.plan(sourceSize: PixelSize(width: 1944, height: 2592), pair: .portraitAndLandscape, quality: .hd1080)
        XCTAssertEqual(plan.outputs.map(\.id), ["9:16", "16:9"])
    }
}
