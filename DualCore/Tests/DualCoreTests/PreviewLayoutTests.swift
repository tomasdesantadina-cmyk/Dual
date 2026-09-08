import XCTest
@testable import DualCore

final class PreviewLayoutTests: XCTestCase {

    func testPortraitAndLandscapeFitComfortably() {
        let layout = PreviewLayout.compute(availableWidth: 360, availableHeight: 600, aspects: FormatPair.portraitAndLandscape.aspects)
        XCTAssertEqual(layout.panes.count, 2)
        let portrait = layout.panes[0]
        let landscape = layout.panes[1]
        XCTAssertEqual(portrait.aspect, .portrait9x16)
        XCTAssertEqual(portrait.width, 360 * PreviewLayout.tallPaneWidthFraction, accuracy: 0.01)
        XCTAssertEqual(portrait.height, portrait.width * 16 / 9, accuracy: 0.01)
        XCTAssertEqual(landscape.width, 360, accuracy: 0.01)
        XCTAssertEqual(landscape.height, 360 * 9 / 16, accuracy: 0.01)
        XCTAssertLessThanOrEqual(layout.totalHeight, 600)
    }

    func testStackIsScaledDownWhenTooTall() {
        let layout = PreviewLayout.compute(availableWidth: 360, availableHeight: 300, aspects: FormatPair.portraitAndSquare.aspects)
        XCTAssertLessThanOrEqual(layout.totalHeight, 300.0001)
        for pane in layout.panes {
            XCTAssertEqual(pane.width / pane.height, pane.aspect.value, accuracy: 0.001)
        }
        XCTAssertLessThan(layout.panes[1].width, 360)
    }

    func testOrderFollowsInput() {
        let layout = PreviewLayout.compute(availableWidth: 400, availableHeight: 800, aspects: [.landscape16x9, .portrait9x16])
        XCTAssertEqual(layout.panes.map(\.aspect), [.landscape16x9, .portrait9x16])
        XCTAssertEqual(layout.panes.map(\.id), ["16:9", "9:16"])
    }

    func testDegenerateInput() {
        XCTAssertTrue(PreviewLayout.compute(availableWidth: 0, availableHeight: 100, aspects: [.square]).panes.isEmpty)
        XCTAssertTrue(PreviewLayout.compute(availableWidth: 100, availableHeight: 100, aspects: []).panes.isEmpty)
    }
}
