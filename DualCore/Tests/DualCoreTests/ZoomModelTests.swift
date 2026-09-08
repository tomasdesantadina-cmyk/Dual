import XCTest
@testable import DualCore

final class ZoomModelTests: XCTestCase {

    let triple = ZoomModel(minZoom: 1, maxZoom: 123.75, switchOverFactors: [2, 6], hasUltraWide: true)
    let dualWide = ZoomModel(minZoom: 1, maxZoom: 16, switchOverFactors: [2], hasUltraWide: true)
    let wideTele = ZoomModel(minZoom: 1, maxZoom: 16, switchOverFactors: [2], hasUltraWide: false)

    func testTripleCameraDisplayFactors() {
        XCTAssertEqual(triple.wideFactor, 2)
        XCTAssertEqual(triple.displayFactor(for: 1), 0.5)
        XCTAssertEqual(triple.displayFactor(for: 2), 1)
        XCTAssertEqual(triple.displayFactor(for: 6), 3)
        XCTAssertEqual(triple.presets, [0.5, 1, 3])
        XCTAssertEqual(triple.maxZoom, 20, "display zoom capped at 10x")
    }

    func testDualWideOffersDigitalTwoX() {
        XCTAssertEqual(dualWide.presets, [0.5, 1, 2])
    }

    func testWideTelePairWithoutUltraWide() {
        XCTAssertEqual(wideTele.wideFactor, 1)
        XCTAssertEqual(wideTele.presets, [1, 2])
        XCTAssertEqual(wideTele.maxZoom, 10)
    }

    func testSingleCamera() {
        XCTAssertEqual(ZoomModel.singleCamera.presets, [1, 2])
        XCTAssertEqual(ZoomModel.singleCamera.label(forZoom: 1), "1x")
    }

    func testPresetCycling() {
        XCTAssertEqual(triple.nextPresetZoom(after: 2), 6)
        XCTAssertEqual(triple.nextPresetZoom(after: 6), 1)
        XCTAssertEqual(triple.nextPresetZoom(after: 1), 2)
        XCTAssertEqual(triple.nextPresetZoom(after: 4.2), 6)
    }

    func testClampingAndPinch() {
        XCTAssertEqual(triple.clamped(0.2), 1)
        XCTAssertEqual(triple.clamped(500), 20)
        XCTAssertEqual(triple.clamped(.nan), 2)
        XCTAssertEqual(triple.zoom(forPinchScale: 2, startZoom: 2), 4)
        XCTAssertEqual(triple.zoom(forPinchScale: 0, startZoom: 2), 2)
        XCTAssertEqual(triple.zoom(forDisplayFactor: 3), 6)
    }

    func testLabels() {
        XCTAssertEqual(ZoomModel.label(forDisplayFactor: 0.5), "0.5x")
        XCTAssertEqual(ZoomModel.label(forDisplayFactor: 1.0), "1x")
        XCTAssertEqual(ZoomModel.label(forDisplayFactor: 2.05), "2.1x")
        XCTAssertEqual(ZoomModel.label(forDisplayFactor: 2.96), "3x")
        XCTAssertEqual(ZoomModel.label(forDisplayFactor: 10), "10x")
        XCTAssertEqual(ZoomModel.label(forDisplayFactor: .nan), "1x")
        XCTAssertEqual(triple.label(forZoom: 4.2), "2.1x")
    }

    func testDegenerateInputs() {
        let odd = ZoomModel(minZoom: .nan, maxZoom: .infinity, switchOverFactors: [-1, .nan, 2], hasUltraWide: true)
        XCTAssertEqual(odd.minZoom, 1)
        XCTAssertEqual(odd.switchOverFactors, [2])
        XCTAssertEqual(odd.maxZoom, 20)
    }
}
