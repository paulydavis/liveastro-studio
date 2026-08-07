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

    // MARK: - Zoom about a point (zoom-to-cursor)

    private let view = CGSize(width: 400, height: 300)
    private let fitted = CGSize(width: 1000, height: 800)   // overflows at scale>~0.4 → room to pan

    func testZoomAboutCenterReducesToCenterAnchor() {
        let center = CGPoint(x: 200, y: 150)
        let start = ZoomPanState(scale: 2, offset: CGSize(width: 30, height: -20))
        let out = ZoomPanState.zoomed(toScale: 4, about: center, viewSize: view,
                                      from: start, fittedContentSize: fitted)
        // center anchor → offset scales by s1/s0 = 2, then clamp
        let expected = ZoomPanState.clampedOffset(CGSize(width: 60, height: -40),
                                                  scale: 4, viewSize: view, fittedContentSize: fitted)
        XCTAssertEqual(out.scale, 4, accuracy: 1e-9)
        XCTAssertEqual(out.offset.width, expected.width, accuracy: 1e-6)
        XCTAssertEqual(out.offset.height, expected.height, accuracy: 1e-6)
    }

    func testZoomAboutOffCenterKeepsTargetStationary() {
        // Pick a point + scale change where the clamp is NOT active, so the
        // content point under the cursor must remain under the cursor.
        let p = CGPoint(x: 240, y: 130)                    // slightly off-center
        let start = ZoomPanState(scale: 2, offset: .zero)
        let s1: CGFloat = 2.2                              // small change → stays unclamped
        let out = ZoomPanState.zoomed(toScale: s1, about: p, viewSize: view,
                                      from: start, fittedContentSize: fitted)
        // Content-relative-to-center coordinate under the cursor, before and after,
        // must match: c = (P - offset)/scale.
        let P = CGSize(width: p.x - view.width/2, height: p.y - view.height/2)
        let cBefore = CGSize(width: (P.width - start.offset.width)/start.scale,
                             height: (P.height - start.offset.height)/start.scale)
        let cAfter = CGSize(width: (P.width - out.offset.width)/out.scale,
                            height: (P.height - out.offset.height)/out.scale)
        XCTAssertEqual(cAfter.width, cBefore.width, accuracy: 1e-6)
        XCTAssertEqual(cAfter.height, cBefore.height, accuracy: 1e-6)
    }

    func testZoomAboutRespectsClamp() {
        let p = CGPoint(x: 400, y: 300)                    // extreme corner
        let start = ZoomPanState(scale: 4, offset: .zero)
        let out = ZoomPanState.zoomed(toScale: 6, about: p, viewSize: view,
                                      from: start, fittedContentSize: fitted)
        let maxX = max(0, (fitted.width * 6 - view.width) / 2)
        let maxY = max(0, (fitted.height * 6 - view.height) / 2)
        XCTAssertLessThanOrEqual(abs(out.offset.width), maxX + 1e-6)
        XCTAssertLessThanOrEqual(abs(out.offset.height), maxY + 1e-6)
    }

    func testZoomAboutDegenerateGuards() {
        let start = ZoomPanState(scale: 2, offset: CGSize(width: 5, height: 5))
        // zero view → return current unchanged
        let z = ZoomPanState.zoomed(toScale: 4, about: .zero, viewSize: .zero,
                                    from: start, fittedContentSize: fitted)
        XCTAssertEqual(z, start)
    }

}
