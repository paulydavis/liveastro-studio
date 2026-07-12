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
    private let rejection: RejectionMethod
    /// Serializes process()/reseed()/currentStack()/stackFrameCount: reseed() runs on the
    /// main thread while process() runs on the pipeline's consume task. A reseed issued
    /// mid-frame applies before the NEXT frame (the intended UX).
    private let lock = NSLock()
    private var accumulator: StackAccumulator?
    private var referenceStars: [Star] = []
    private var referenceSize: (w: Int, h: Int)?
    private var referenceChannels: Int?
    /// Session-total accepted frames; deliberately NOT reset by reseed()
    /// (per-stack progress is stackFrameCount).
    public private(set) var acceptedCount = 0
    /// Session-total rejected frames; deliberately NOT reset by reseed().
    public private(set) var rejectedCount = 0
    /// Session-total automatic reseeds (reference cleared after systematic
    /// registration failure). Not reset by reseed(), like acceptedCount.
    public private(set) var autoReseedCount = 0
    private let autoReseedThreshold: Int
    private var consecutiveNoTransform = 0

    /// seedMinStars: must comfortably exceed minMatches (8); 15 gives
    /// C(15,3)=455 triangles for reliable initial matching.
    public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0,
                rejection: RejectionMethod = NoRejection(), autoReseedThreshold: Int = 6) {
        self.seedMinStars = seedMinStars
        self.minMatches = minMatches
        self.inlierTolerance = inlierTolerance
        self.rejection = rejection
        self.autoReseedThreshold = autoReseedThreshold
    }

    public func reseed() {
        lock.withLock {
            accumulator = nil
            referenceStars = []
            referenceSize = nil
            referenceChannels = nil
            rejection.reset()
        }
    }

    public func currentStack() -> AstroImage? {
        lock.withLock { accumulator?.mean() }
    }

    /// Frames in the CURRENT stack (resets on reseed, unlike acceptedCount).
    public var stackFrameCount: Int {
        lock.withLock { accumulator?.frameCount ?? 0 }
    }

    /// The current per-pixel coverage map, or nil if there is no active stack.
    public func currentCoverage() -> [Float]? {
        lock.withLock { accumulator?.coverage() }
    }

    public func process(_ frame: RawFrame) -> StackOutcome {
        lock.withLock { processLocked(frame) }
    }

    private func processLocked(_ frame: RawFrame) -> StackOutcome {
        let raw = frame.image
        // Degenerate frames (a half-res luminance needs at least a 2×2 source) would
        // crash star detection / superpixel binning — reject before any luminance work.
        guard raw.width >= 2, raw.height >= 2 else {
            rejectedCount += 1
            return .rejected(.dimensionMismatch)
        }
        if let size = referenceSize, size != (raw.width, raw.height) {
            rejectedCount += 1
            return .rejected(.dimensionMismatch)
        }
        let (lum, hw, hh) = Self.halfResLuminance(frame: frame)
        let stars = StarDetector.detect(luminance: lum, width: hw, height: hh)

        if referenceSize == nil {
            guard stars.count >= seedMinStars else {
                rejectedCount += 1
                return .rejected(.insufficientStars(found: stars.count))
            }
            let rgb = displayRGB(frame)
            let ones = [Float](repeating: 1, count: rgb.width * rgb.height)
            let seed = rejection.apply(rgb, mask: ones)
            let acc = StackAccumulator(width: rgb.width, height: rgb.height, channels: rgb.channels)
            acc.add(seed, mask: ones)
            accumulator = acc
            referenceStars = stars
            referenceSize = (raw.width, raw.height)
            referenceChannels = rgb.channels
            acceptedCount += 1
            consecutiveNoTransform = 0
            return .becameReference
        }

        // 3 = TriangleMatcher minimum (one triangle); RANSAC's minMatches is
        // enforced later by TransformSolver.
        guard stars.count >= 3 else {
            rejectedCount += 1
            return .rejected(.insufficientStars(found: stars.count))
        }
        let pairs = TriangleMatcher.correspondences(source: stars, target: referenceStars)
        guard let half = TransformSolver.solve(source: stars, target: referenceStars, pairs: pairs,
                                               minMatches: minMatches, inlierTolerance: inlierTolerance)
        else {
            rejectedCount += 1
            consecutiveNoTransform += 1
            if autoReseedThreshold > 0 && consecutiveNoTransform >= autoReseedThreshold {
                // Systematic mismatch ⇒ the reference is probably a wrong-target
                // frame. Clear it so the next ≥seedMinStars frame re-seeds.
                referenceStars = []
                referenceSize = nil
                referenceChannels = nil
                accumulator = nil
                consecutiveNoTransform = 0
                autoReseedCount += 1
            }
            return .rejected(.noTransform)
        }
        let rgb = displayRGB(frame)
        guard rgb.channels == referenceChannels else {
            rejectedCount += 1
            return .rejected(.dimensionMismatch)
        }
        // Invariant: referenceSize != nil (checked above) implies the accumulator was
        // created when the reference seeded. Guard rather than trap so a violated
        // invariant degrades to a rejection instead of crashing the session.
        // Deliberately does NOT bump consecutiveNoTransform: this is the unreachable
        // invariant-degradation path, not a real target mismatch, so it must not
        // count toward auto-reseed (would only ever under-count, never spuriously trip).
        guard let accumulator else {
            rejectedCount += 1
            return .rejected(.noTransform)
        }
        let (warped, mask) = Warp.apply(rgb, transform: half.liftedToFullResolution())
        let cleaned = rejection.apply(warped, mask: mask)
        accumulator.add(cleaned, mask: mask)
        acceptedCount += 1
        consecutiveNoTransform = 0
        return .stacked(frameCount: accumulator.frameCount)
    }

    /// Half-res superpixel luminance in DISPLAY orientation (flip rows if bottom-up).
    /// Internal so parity tests exercise the exact production binning.
    static func halfResLuminance(frame: RawFrame, minRows: Int = 64)
        -> (lum: [Float], width: Int, height: Int) {
        let raw = frame.image
        let hw = raw.width / 2, hh = raw.height / 2
        var lum = [Float](repeating: 0, count: hw * hh)
        let bottomUp = frame.bottomUp
        let rw = raw.width
        raw.pixels.withUnsafeBufferPointer { p in
            lum.withUnsafeMutableBufferPointer { lumBuf in
                Parallel.rows(hh, minRows: minRows) { rows in
                    for j in rows {
                        let srcRow = bottomUp ? (hh - 1 - j) : j
                        for i in 0..<hw {
                            let r0 = 2 * srcRow * rw + 2 * i
                            let r1 = r0 + rw
                            lumBuf[j * hw + i] = (p[r0] + p[r0 + 1] + p[r1] + p[r1 + 1]) / 4
                        }
                    }
                }
            }
        }
        return (lum, hw, hh)
    }

    /// Debayer in stored order (never flip the CFA), then flip rows to top-down display.
    /// RawFrame contract: bayerPattern != nil implies channels == 1 (a violated
    /// contract traps in Debayer.bilinear rather than silently mis-rendering).
    private func displayRGB(_ frame: RawFrame, minRows: Int = 64) -> AstroImage {
        var rgb: AstroImage
        if let pattern = frame.bayerPattern, frame.image.channels == 1 {
            rgb = Debayer.bilinear(cfa: frame.image, pattern: pattern, minRows: minRows)
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

    /// A frame that registered against the current reference; ready to warp+commit.
    public struct RegisteredFrame {
        public let transform: SimilarityTransform   // half-res transform (lift in warp)
        public let rgb: AstroImage                  // display-oriented RGB
    }

    /// Establish the fixed reference from `frame` if it has ≥ seedMinStars.
    /// Returns true on success (frame counts as accepted). Serial — call before
    /// any concurrent register(). Bumps rejectedCount on a too-few-stars frame.
    public func seedReference(_ frame: RawFrame, minRows: Int) -> Bool {
        lock.withLock {
            let raw = frame.image
            guard raw.width >= 2, raw.height >= 2 else { rejectedCount += 1; return false }
            let (lum, hw, hh) = Self.halfResLuminance(frame: frame, minRows: minRows)
            let stars = StarDetector.detect(luminance: lum, width: hw, height: hh)
            guard stars.count >= seedMinStars else { rejectedCount += 1; return false }
            let rgb = displayRGB(frame, minRows: minRows)
            let ones = [Float](repeating: 1, count: rgb.width * rgb.height)
            let seed = rejection.apply(rgb, mask: ones)
            let acc = StackAccumulator(width: rgb.width, height: rgb.height, channels: rgb.channels)
            acc.add(seed, mask: ones, minRows: minRows)
            accumulator = acc
            referenceStars = stars
            referenceSize = (raw.width, raw.height)
            referenceChannels = rgb.channels
            acceptedCount += 1
            consecutiveNoTransform = 0
            return true
        }
    }

    /// Register `frame` against the ALREADY-SEEDED, immutable reference. Pure —
    /// mutates no engine state, so it is safe to call concurrently from a worker
    /// pool (reference state is set once by seedReference before the pool starts
    /// and is never mutated during batch import). Returns nil if rejected.
    public func register(_ frame: RawFrame, minRows: Int) -> RegisteredFrame? {
        let raw = frame.image
        guard raw.width >= 2, raw.height >= 2 else { return nil }
        guard let refSize = referenceSize, refSize == (raw.width, raw.height) else { return nil }
        let (lum, hw, hh) = Self.halfResLuminance(frame: frame, minRows: minRows)
        let stars = StarDetector.detect(luminance: lum, width: hw, height: hh)
        guard stars.count >= 3 else { return nil }
        let pairs = TriangleMatcher.correspondences(source: stars, target: referenceStars)
        guard let half = TransformSolver.solve(source: stars, target: referenceStars, pairs: pairs,
                                               minMatches: minMatches, inlierTolerance: inlierTolerance)
        else { return nil }
        let rgb = displayRGB(frame, minRows: minRows)
        guard rgb.channels == referenceChannels else { return nil }
        return RegisteredFrame(transform: half, rgb: rgb)
    }

    /// Warp a registered frame to reference alignment. Pure, concurrent-safe.
    public func warp(_ reg: RegisteredFrame, minRows: Int) -> (image: AstroImage, mask: [Float]) {
        Warp.apply(reg.rgb, transform: reg.transform.liftedToFullResolution(), minRows: minRows)
    }

    /// Accumulate a warped frame into the shared stack under the engine lock.
    /// Bumps acceptedCount. Rejection filtering runs here (serial), preserving any
    /// stateful RejectionMethod. Call from the single serial consumer.
    public func commit(image: AstroImage, mask: [Float], minRows: Int) {
        lock.withLock {
            guard let accumulator else { return }
            let cleaned = rejection.apply(image, mask: mask)
            accumulator.add(cleaned, mask: mask, minRows: minRows)
            acceptedCount += 1
            consecutiveNoTransform = 0
        }
    }

    /// Record a batch rejection (bumps rejectedCount) under the lock.
    public func commitRejection() {
        lock.withLock { rejectedCount += 1 }
    }
}
