import XCTest
import CoreGraphics
@testable import LiveAstroCore

final class ZoomPanStateTests: XCTestCase {
    func testClampScale() {
        XCTAssertEqual(ZoomPanState.clampScale(0.3), 1)
        XCTAssertEqual(ZoomPanState.clampScale(1), 1)
        XCTAssertEqual(ZoomPanState.clampScale(5), 5)
        XCTAssertEqual(ZoomPanState.clampScale(8), 8)
        XCTAssertEqual(ZoomPanState.clampScale(12), 8)   // maxScale
    }

    func testFitDefault() {
        XCTAssertEqual(ZoomPanState.fit.scale, 1)
        XCTAssertEqual(ZoomPanState.fit.offset, .zero)
        XCTAssertEqual(ZoomPanState(), ZoomPanState.fit)
    }

    func testNoPanAtFit() {
        // scale 1: content fits → any proposed offset clamps to zero (matched + letterboxed).
        let view = CGSize(width: 100, height: 100)
        XCTAssertEqual(ZoomPanState.clampedOffset(CGSize(width: 99, height: 99), scale: 1,
                       viewSize: view, fittedContentSize: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(ZoomPanState.clampedOffset(CGSize(width: 40, height: -40), scale: 1,
                       viewSize: view, fittedContentSize: CGSize(width: 100, height: 60)), .zero)
    }

    func testZoomedBoundsSquare() {
        // square view + square content, scale 2 → overflow = view; maxOffset = view/2 = 50.
        let view = CGSize(width: 100, height: 100)
        let content = CGSize(width: 100, height: 100)
        XCTAssertEqual(ZoomPanState.clampedOffset(CGSize(width: 80, height: 80), scale: 2,
                       viewSize: view, fittedContentSize: content), CGSize(width: 50, height: 50))
        XCTAssertEqual(ZoomPanState.clampedOffset(CGSize(width: 30, height: -30), scale: 2,
                       viewSize: view, fittedContentSize: content), CGSize(width: 30, height: -30))
    }

    func testPerAxisClamp() {
        // landscape view, portrait content fitted to height → at scale 2 only the
        // vertical axis overflows; horizontal pan is pinned to 0.
        let view = CGSize(width: 200, height: 100)
        let content = CGSize(width: 50, height: 100)          // fitted at scale 1
        let out = ZoomPanState.clampedOffset(CGSize(width: 40, height: 40), scale: 2,
                       viewSize: view, fittedContentSize: content)
        XCTAssertEqual(out.width, 0)                          // 2*50=100 < 200 → no horizontal overflow
        XCTAssertEqual(out.height, 40)                        // 2*100=200 → maxY=(200-100)/2=50 → 40 passes
    }

    func testReclampOnZoomOut() {
        // A pan valid at scale 4 must pull back to zero when scale returns to 1.
        let view = CGSize(width: 100, height: 100)
        let content = CGSize(width: 100, height: 100)
        let panned = CGSize(width: 40, height: 40)            // fine at scale 4
        XCTAssertEqual(ZoomPanState.clampedOffset(panned, scale: 1,
                       viewSize: view, fittedContentSize: content), .zero)
    }

    func testDegenerateSizes() {
        XCTAssertEqual(ZoomPanState.clampedOffset(CGSize(width: 10, height: 10), scale: 2,
                       viewSize: .zero, fittedContentSize: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(ZoomPanState.clampedOffset(CGSize(width: 10, height: 10), scale: 2,
                       viewSize: CGSize(width: 100, height: 100), fittedContentSize: .zero), .zero)
    }
}
