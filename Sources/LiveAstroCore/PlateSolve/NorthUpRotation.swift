import CoreGraphics
import Foundation

/// Rotate a DISPLAY image so celestial north points up, from a solved `WCS` (sub-project 3b).
///
/// The solver reports the frame as the north-up grid rotated by `+rotationDegrees` (see `PlateSolver`
/// and `PlateSolverTests.projectThroughWCS`: `frame = R(-rotationDegrees) · grid`). So rotating the
/// image by `+rotationDegrees` restores the grid's north-up orientation. This is parity-independent:
/// the mirror only swaps east/west, north stays north, so we do NOT force an east-left flip — the
/// image keeps the handedness the user's optics produced.
///
/// `displayRotationRadians` is the pure geometric truth (self-consistent with the solver's forward
/// model, verified by `NorthUpRotationTests`). The pixel-space realisation in `apply(...)` goes through
/// CoreGraphics, whose y-up convention vs the top-down display is reconciled EMPIRICALLY by the gated
/// real-frame test — if north comes out down, the fix is the draw transform in `apply`, not this angle.
public enum NorthUpRotation {
    /// Rotations at or below this magnitude crop-to-fill (no black corners); larger ones letterbox the
    /// full rotated frame so a heavily-rotated image is never cropped. ~15°.
    public static let autoZoomMaxAngle = 15.0 * .pi / 180.0

    /// Angle (radians) to rotate the top-down display so north is up. See type doc for the derivation.
    public static func displayRotationRadians(wcs: WCS) -> Double {
        wcs.rotationDegrees * .pi / 180.0
    }

    /// Rotate `cg` to north-up. `autoZoom`: when the rotation is small, scale-to-fill the original
    /// canvas (no black corners); otherwise return the full rotated bounding box (letterbox).
    public static func apply(_ cg: CGImage, wcs: WCS, autoZoom: Bool) -> CGImage {
        let angle = displayRotationRadians(wcs: wcs)
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let c = abs(cos(angle)), s = abs(sin(angle))
        let small = abs(atan2(sin(angle), cos(angle))) <= autoZoomMaxAngle

        // Output canvas + how much to scale the drawn image.
        let outW: CGFloat, outH: CGFloat, scale: CGFloat
        if autoZoom && small {
            // Crop-to-fill: keep the original frame size, zoom just enough to bury the black corners.
            outW = w; outH = h
            scale = CGFloat(c) + CGFloat(max(w / h, h / w)) * CGFloat(s)   // guarantees coverage
        } else {
            // Letterbox: the full rotated bounding box, no scaling.
            outW = w * c + h * s
            outH = w * s + h * c
            scale = 1
        }
        let outWi = max(1, Int(outW.rounded())), outHi = max(1, Int(outH.rounded()))

        guard let space = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: outWi, height: outHi, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        // Top-down draw space so the image's row 0 stays at the top, then rotate about the centre.
        ctx.translateBy(x: 0, y: CGFloat(outHi))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(outWi) / 2, y: CGFloat(outHi) / 2)
        ctx.rotate(by: CGFloat(angle))
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(cg, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage() ?? cg
    }
}
