import XCTest
import CoreGraphics
@testable import LiveAstroCore

final class NorthUpRotationTests: XCTestCase {
    private let ARCSEC_PER_RAD = 206264.806247

    /// Forward model (same as PlateSolverTests.projectThroughWCS): where a camera with this WCS sees a
    /// catalog star, in top-down frame pixels.
    private func projectThroughWCS(ra: Double, dec: Double, w: Int, h: Int,
                                   cra: Double, cdec: Double, rotDeg: Double, scale: Double, parity: Bool)
        -> (x: Double, y: Double) {
        let p = GnomonicProjection.project(ra: ra, dec: dec, centerRA: cra, centerDec: cdec)
        var gx = Double(w) / 2 + (p.xi * ARCSEC_PER_RAD) / scale
        let gy = Double(h) / 2 - (p.eta * ARCSEC_PER_RAD) / scale
        if parity { gx = Double(w) - gx }
        let cx = Double(w) / 2, cy = Double(h) / 2
        let th = -rotDeg * .pi / 180
        let dx = gx - cx, dy = gy - cy
        return (cx + cos(th) * dx - sin(th) * dy, cy + sin(th) * dx + cos(th) * dy)
    }

    /// Rotate a frame point about center by the display rotation (same matrix, inverse angle).
    private func displayRotate(_ pt: (x: Double, y: Double), w: Int, h: Int, angle: Double)
        -> (x: Double, y: Double) {
        let cx = Double(w) / 2, cy = Double(h) / 2
        let dx = pt.x - cx, dy = pt.y - cy
        return (cx + cos(angle) * dx - sin(angle) * dy, cy + sin(angle) * dx + cos(angle) * dy)
    }

    /// After the display rotation, a star due-NORTH of center must land ABOVE center (smaller top-down y)
    /// and stay near the vertical axis — for a range of frame rotations and both parities.
    func testNorthEndsUpAboveCenter() {
        let w = 1000, h = 800, scale = 2.0, cra = 150.0, cdec = 22.0
        for rotDeg in [0.0, 30.0, -63.0, 95.0, 175.0] {
            for parity in [false, true] {
                let wcs = WCS(centerRA: cra, centerDec: cdec, rotationDegrees: rotDeg,
                              pixelScaleArcsec: scale, parity: parity, inlierCount: 20)
                let angle = NorthUpRotation.displayRotationRadians(wcs: wcs)
                // a star ~0.1° due north of center
                let north = projectThroughWCS(ra: cra, dec: cdec + 0.1, w: w, h: h,
                                              cra: cra, cdec: cdec, rotDeg: rotDeg, scale: scale, parity: parity)
                let r = displayRotate(north, w: w, h: h, angle: angle)
                XCTAssertLessThan(r.y, Double(h) / 2 - 1, "north not up for rot=\(rotDeg) parity=\(parity) (y=\(r.y))")
                XCTAssertEqual(r.x, Double(w) / 2, accuracy: 1.0, "north drifted off the vertical for rot=\(rotDeg) parity=\(parity)")
            }
        }
    }

    /// East of center lands LEFT for a normal (mirrored-parity) sky image, RIGHT for the flipped parity —
    /// i.e. the display keeps the image's handedness (no forced east-left flip).
    func testEastSideFollowsParity() {
        let w = 1000, h = 800, scale = 2.0, cra = 150.0, cdec = 22.0, rotDeg = 40.0
        for parity in [false, true] {
            let wcs = WCS(centerRA: cra, centerDec: cdec, rotationDegrees: rotDeg,
                          pixelScaleArcsec: scale, parity: parity, inlierCount: 20)
            let angle = NorthUpRotation.displayRotationRadians(wcs: wcs)
            let east = projectThroughWCS(ra: cra + 0.1 / cos(cdec * .pi/180), dec: cdec, w: w, h: h,
                                         cra: cra, cdec: cdec, rotDeg: rotDeg, scale: scale, parity: parity)
            let r = displayRotate(east, w: w, h: h, angle: angle)
            if parity { XCTAssertLessThan(r.x, Double(w) / 2 - 1, "mirrored: east should be left") }
            else { XCTAssertGreaterThan(r.x, Double(w) / 2 + 1, "normal: east should be right") }
        }
    }

    private func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// An image with a bright marker at a known offset from center; rest dark.
    private func markerImage(_ w: Int, _ h: Int, mx: Int, my: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext is y-up; to place the marker at top-down row `my`, draw at y = h-1-my.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: mx - 6, y: (h - 1 - my) - 6, width: 12, height: 12))
        return ctx.makeImage()!
    }

    /// Brightest-pixel centroid in TOP-DOWN coords (y down from the top).
    private func brightestCentroid(_ cg: CGImage) -> (x: Double, y: Double) {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))   // CGImage draws right-side-up here
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<h { for x in 0..<w {
            if buf[(y * w + x) * 4] > 128 { sx += Double(x); sy += Double(y); n += 1 }
        } }
        return n > 0 ? (sx / n, sy / n) : (Double(w)/2, Double(h)/2)
    }

    /// A grayscale (DeviceGray) display — what AutoStretch.makeCGImage produces for a MONO session —
    /// must still rotate. (Adversarial review: an RGB-only context silently no-ops gray inputs.)
    func testRotatesGrayscaleImage() {
        let g = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 200,
                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        g.setFillColor(gray: 0.5, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let gray = g.makeImage()!
        XCTAssertEqual(gray.colorSpace?.model, .monochrome, "precondition: input is gray")
        let wcs = WCS(centerRA: 0, centerDec: 0, rotationDegrees: 90, pixelScaleArcsec: 1, parity: false, inlierCount: 20)
        let out = NorthUpRotation.apply(gray, wcs: wcs, autoZoom: false)
        XCTAssertEqual(out.width, 120, "gray image must actually rotate (90°: 200×120 → 120×200)")
        XCTAssertEqual(out.height, 200)
    }

    /// The CoreGraphics realisation `apply` must move pixels the SAME direction the pure-math rotation
    /// predicts — otherwise "north-up" would render upside down. A marker at the RIGHT-middle, rotated
    /// by rotationDegrees=90, must land in the BOTTOM half of the output (per the top-down math:
    /// offset (+d,0) → (0,+d)). If this lands top, the sign in `apply` is wrong.
    func testApplyRotationMatchesMathDirection() {
        let w = 200, h = 120
        let img = markerImage(w, h, mx: 175, my: 60)   // right-middle
        let wcs = WCS(centerRA: 0, centerDec: 0, rotationDegrees: 90, pixelScaleArcsec: 1, parity: false, inlierCount: 20)
        let out = NorthUpRotation.apply(img, wcs: wcs, autoZoom: false)
        let c = brightestCentroid(out)
        XCTAssertGreaterThan(c.y, Double(out.height) / 2,
                             "marker should rotate to the BOTTOM (top-down math); got y=\(c.y)/\(out.height) — apply sign is inverted")
    }

    /// Auto-zoom: a SMALL rotation keeps the original canvas (crop-to-fill); a LARGE rotation returns the
    /// full rotated bounding box (letterbox).
    func testAutoZoomFramingDimensions() {
        let w = 400, h = 300
        let img = solidImage(w, h)
        func wcs(_ deg: Double) -> WCS {
            WCS(centerRA: 0, centerDec: 0, rotationDegrees: deg, pixelScaleArcsec: 1, parity: false, inlierCount: 20)
        }
        // Small angle (5°) → same dims as input.
        let smallOut = NorthUpRotation.apply(img, wcs: wcs(5), autoZoom: true)
        XCTAssertEqual(smallOut.width, w)
        XCTAssertEqual(smallOut.height, h)
        // Large angle (90°) → rotated bounding box (a 400×300 rotated 90° → 300×400).
        let bigOut = NorthUpRotation.apply(img, wcs: wcs(90), autoZoom: true)
        XCTAssertEqual(bigOut.width, h)
        XCTAssertEqual(bigOut.height, w)
        // autoZoom off → always the bounding box, even for a small angle.
        let noZoom = NorthUpRotation.apply(img, wcs: wcs(5), autoZoom: false)
        XCTAssertGreaterThanOrEqual(noZoom.width, w)   // bbox of a 5° rotation is slightly larger
    }
}
