import Foundation

public enum StackOutcome: Equatable {
    case becameReference
    case stacked(frameCount: Int)
    case rejected(RejectionReason)
}

public enum RejectionReason: Equatable {
    case insufficientStars(found: Int)
    case noTransform
    case dimensionMismatch
}

/// Native stacking core (spec §4.2): registration on half-res superpixel luminance,
/// full-res accumulation. Rejection is registration-failure only (spec §3).
public final class StackEngine {
    private let seedMinStars: Int
    private let minMatches: Int
    private let inlierTolerance: Double
    private var accumulator: StackAccumulator?
    private var referenceStars: [Star] = []
    private var referenceSize: (w: Int, h: Int)?
    private var referenceChannels: Int?
    public private(set) var acceptedCount = 0
    public private(set) var rejectedCount = 0

    public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0) {
        self.seedMinStars = seedMinStars
        self.minMatches = minMatches
        self.inlierTolerance = inlierTolerance
    }

    public func reseed() {
        accumulator = nil
        referenceStars = []
        referenceSize = nil
        referenceChannels = nil
    }

    public func currentStack() -> AstroImage? { accumulator?.mean() }

    public func process(_ frame: RawFrame) -> StackOutcome {
        let raw = frame.image
        if let size = referenceSize, size != (raw.width, raw.height) {
            rejectedCount += 1
            return .rejected(.dimensionMismatch)
        }
        // Half-res superpixel luminance in DISPLAY orientation (flip rows if bottom-up).
        let hw = raw.width / 2, hh = raw.height / 2
        var lum = [Float](repeating: 0, count: hw * hh)
        raw.pixels.withUnsafeBufferPointer { p in
            for j in 0..<hh {
                let srcRow = frame.bottomUp ? (hh - 1 - j) : j
                for i in 0..<hw {
                    let r0 = 2 * srcRow * raw.width + 2 * i
                    let r1 = r0 + raw.width
                    lum[j * hw + i] = (p[r0] + p[r0 + 1] + p[r1] + p[r1 + 1]) / 4
                }
            }
        }
        let stars = StarDetector.detect(luminance: lum, width: hw, height: hh)

        if referenceSize == nil {
            guard stars.count >= seedMinStars else {
                rejectedCount += 1
                return .rejected(.insufficientStars(found: stars.count))
            }
            let rgb = displayRGB(frame)
            let acc = StackAccumulator(width: rgb.width, height: rgb.height, channels: rgb.channels)
            acc.add(rgb, mask: [Float](repeating: 1, count: rgb.width * rgb.height))
            accumulator = acc
            referenceStars = stars
            referenceSize = (raw.width, raw.height)
            referenceChannels = rgb.channels
            acceptedCount += 1
            return .becameReference
        }

        guard stars.count >= 3 else {
            rejectedCount += 1
            return .rejected(.insufficientStars(found: stars.count))
        }
        let pairs = TriangleMatcher.correspondences(source: stars, target: referenceStars)
        guard let half = TransformSolver.solve(source: stars, target: referenceStars, pairs: pairs,
                                               minMatches: minMatches, inlierTolerance: inlierTolerance)
        else {
            rejectedCount += 1
            return .rejected(.noTransform)
        }
        let rgb = displayRGB(frame)
        guard rgb.channels == referenceChannels else {
            rejectedCount += 1
            return .rejected(.dimensionMismatch)
        }
        let (warped, mask) = Warp.apply(rgb, transform: half.liftedToFullResolution())
        accumulator!.add(warped, mask: mask)
        acceptedCount += 1
        return .stacked(frameCount: accumulator!.frameCount)
    }

    /// Debayer in stored order (never flip the CFA), then flip rows to top-down display.
    private func displayRGB(_ frame: RawFrame) -> AstroImage {
        var rgb: AstroImage
        if let pattern = frame.bayerPattern, frame.image.channels == 1 {
            rgb = Debayer.bilinear(cfa: frame.image, pattern: pattern)
        } else {
            rgb = frame.image
        }
        guard frame.bottomUp else { return rgb }
        let w = rgb.width, h = rgb.height, plane = w * h
        var flipped = [Float](repeating: 0, count: rgb.pixels.count)
        for c in 0..<rgb.channels {
            for y in 0..<h {
                let src = c * plane + (h - 1 - y) * w
                let dst = c * plane + y * w
                flipped.replaceSubrange(dst..<(dst + w), with: rgb.pixels[src..<(src + w)])
            }
        }
        return AstroImage(width: w, height: h, channels: rgb.channels,
                          pixels: flipped, sourceIsLinear: rgb.sourceIsLinear)
    }
}
