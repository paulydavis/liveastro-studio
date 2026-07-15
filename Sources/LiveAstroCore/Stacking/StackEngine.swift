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
    private let frameWeighting: Bool
    private var weightBaseline: (stars: Int, sigma: Float)?    // set at seed, reset on reseed
    private let normalization: Bool
    private let scaleNormalization: Bool
    private let demosaic: DemosaicMethod
    /// R5: the seed's TILE SAMPLES (not a fitted model). Stored so each sub's reference
    /// model can be re-solved over the SAME masked tile subset as the sub — killing the
    /// seed-vs-sub fit-domain asymmetry (a full-frame seed fit vs a masked sub fit gave
    /// different coeffs over a non-polynomial sky, injecting a spurious differential).
    /// Set at seed (serial, before the concurrent register/warp phase per the batch
    /// contract) and read lock-free in `levelingModels` — same contract as `referenceStars`.
    /// Reset to nil on reseed. nil when normalization is off.
    private var referenceBackgroundSamples: (x: [Double], y: [Double], v: [[Double]?])?
    // R4: degree 2 (R1 rework prototype: degree 1 cannot model a frame-filling nebula differential).
    static let backgroundDegree = 2
    static let weightExponent: Float = 1.0
    static let weightLo: Float = 0.25
    static let weightHi: Float = 4.0
    // Scale-normalization constants (spec: multiplicative scale). Transparency
    // beyond a 2× swing is clouds — weighting/rejection's job, not scaling's.
    static let scaleLo: Float = 0.5
    static let scaleHi: Float = 2.0
    static let minScalePairs = 5

    /// Median matched-star flux ratio (ref/sub) over RANSAC inlier pairs — the
    /// sub's transparency correction. Pure. Invalid pairs (non-finite or ≤ 0 flux)
    /// are skipped; fewer than minScalePairs valid pairs ⇒ 1.0 (no scaling).
    public static func scaleFactor(fluxPairs: [(sub: Double, ref: Double)]) -> Float {
        let ratios = fluxPairs.compactMap { p -> Double? in
            guard p.sub.isFinite, p.ref.isFinite, p.sub > 0, p.ref > 0 else { return nil }
            return p.ref / p.sub
        }
        guard ratios.count >= minScalePairs else { return 1.0 }
        let sorted = ratios.sorted()
        let median = sorted[sorted.count / 2]
        return min(max(Float(median), scaleLo), scaleHi)
    }

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
                rejection: RejectionMethod = NoRejection(), autoReseedThreshold: Int = 6,
                frameWeighting: Bool = false, normalization: Bool = false,
                scaleNormalization: Bool = false,
                demosaic: DemosaicMethod = .bilinear) {
        self.seedMinStars = seedMinStars
        self.minMatches = minMatches
        self.inlierTolerance = inlierTolerance
        self.rejection = rejection
        self.autoReseedThreshold = autoReseedThreshold
        self.frameWeighting = frameWeighting
        self.normalization = normalization
        // Gate: scaling pivots about the reference background SURFACE, which only exists
        // when leveling is on. An unleveled sub has no matched background to pivot about —
        // the adversarial repro shows a scalar pivot injects a per-sub pedestal
        // (bg_sub − bg₀)(s − 1). So scaling is only active when leveling is also on.
        self.scaleNormalization = scaleNormalization && normalization
        self.demosaic = demosaic
    }

    public func reseed() {
        lock.withLock {
            accumulator = nil
            referenceStars = []
            referenceSize = nil
            referenceChannels = nil
            weightBaseline = nil
            referenceBackgroundSamples = nil
            rejection.reset()
        }
    }

    /// Per-frame stacking weight from star count + background σ, relative to the
    /// seed (stars₀, σ₀). Returns 1.0 when weighting is off or before seeding.
    public func frameWeight(stars: Int, sigma: Float) -> Float {
        guard frameWeighting, let base = weightBaseline else { return 1.0 }
        let starTerm = powf(Float(stars) / Float(max(base.stars, 1)), Self.weightExponent)
        let noiseTerm = powf(base.sigma / max(sigma, 1e-6), 2)
        return min(max(starTerm * noiseTerm, Self.weightLo), Self.weightHi)
    }

    func setWeightBaselineForTesting(stars: Int, sigma: Float) { weightBaseline = (stars, sigma) }

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
        let (stars, sigma) = StarDetector.detectWithStats(luminance: lum, width: hw, height: hh)

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
            weightBaseline = (stars.count, sigma)
            referenceBackgroundSamples = normalization
                ? BackgroundExtraction.tileSamples(rgb) : nil
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
                weightBaseline = nil
                referenceBackgroundSamples = nil
                rejection.reset()   // else the new field's seed is sigma-clipped against the old field's stats
                consecutiveNoTransform = 0
                autoReseedCount += 1
            }
            return .rejected(.noTransform)
        }
        var scale: Float = 1.0
        if scaleNormalization {
            let ins = TransformSolver.inliers(half, source: stars, target: referenceStars,
                                              pairs: pairs, tolerance: inlierTolerance)
            scale = Self.scaleFactor(fluxPairs: ins.map { (sub: stars[$0.source].flux, ref: referenceStars[$0.target].flux) })
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
        // R5: solve BOTH the sub and reference models over the SAME masked tile subset of the
        // WARPED frame — kills the seed-vs-sub fit-domain asymmetry (C, R5) on top of R4's
        // fit-on-warped (kills rotation-injection C1 / nebula differential C2).
        // Scaling is fused into leveling with a per-pixel reference-background pivot.
        // When the per-frame fit fails (leveling pair nil) NO scaling happens either —
        // consistent with the gate (no matched background surface to pivot about).
        var frame = warped
        if let pair = levelingModels(image: warped, mask: mask) {
            frame = GradientLeveler.apply(warped, subModel: pair.sub, refModel: pair.ref, scale: scale)
        }
        let cleaned = rejection.apply(frame, mask: mask)
        // σ·s: scaling amplifies noise too — weight must see post-scale noise
        accumulator.add(cleaned, mask: mask, frameWeight: frameWeight(stars: stars.count, sigma: sigma * scale))
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
            switch demosaic {
            case .bilinear:
                rgb = Debayer.bilinear(cfa: frame.image, pattern: pattern, minRows: minRows)
            case .rcd:
                rgb = Debayer.rcd(cfa: frame.image, pattern: pattern, minRows: minRows)
            }
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
        public let weight: Float                    // quality-based stacking weight (1.0 when off)
        public let scale: Float                     // matched-flux transparency correction (1.0 when off)
        // R4/R5: backgroundModel removed from RegisteredFrame — fits are now done on the WARPED
        // frame (see levelingModels). Fitting pre-warp injected rotation-induced gradient error (C1).
    }

    /// Establish the fixed reference from `frame` if it has ≥ seedMinStars.
    /// Returns true on success (frame counts as accepted). Serial — call before
    /// any concurrent register(). Bumps rejectedCount on a too-few-stars frame.
    public func seedReference(_ frame: RawFrame, minRows: Int) -> Bool {
        lock.withLock {
            let raw = frame.image
            guard raw.width >= 2, raw.height >= 2 else { rejectedCount += 1; return false }
            let (lum, hw, hh) = Self.halfResLuminance(frame: frame, minRows: minRows)
            let (stars, sigma) = StarDetector.detectWithStats(luminance: lum, width: hw, height: hh)
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
            weightBaseline = (stars.count, sigma)
            referenceBackgroundSamples = normalization
                ? BackgroundExtraction.tileSamples(rgb) : nil
            acceptedCount += 1
            consecutiveNoTransform = 0
            return true
        }
    }

    /// Register `frame` against the ALREADY-SEEDED, immutable reference.
    ///
    /// Pure and lock-free: reads reference state (referenceStars, referenceSize,
    /// referenceChannels) without the lock and mutates nothing, so it is safe to call
    /// CONCURRENTLY from a worker pool.
    ///
    /// CONTRACT: the caller MUST ensure `seedReference(...)` has returned before
    /// issuing any concurrent `register(...)` calls, and MUST NOT mutate the engine
    /// (no `process`, `seedReference`, or `reseed`) during the concurrent phase.
    /// Reference state is established once at seed and treated as immutable for the
    /// duration of a batch import.
    ///
    /// (Swift 5.10: the lock-free reads are safe under this contract; a future
    /// Swift 6 strict-concurrency migration would annotate the reference properties
    /// accordingly.)
    ///
    /// Returns nil if rejected.
    public func register(_ frame: RawFrame, minRows: Int) -> RegisteredFrame? {
        let raw = frame.image
        guard raw.width >= 2, raw.height >= 2 else { return nil }
        guard let refSize = referenceSize, refSize == (raw.width, raw.height) else { return nil } // lock-free read — safe under the batch contract documented above
        let (lum, hw, hh) = Self.halfResLuminance(frame: frame, minRows: minRows)
        let (stars, sigma) = StarDetector.detectWithStats(luminance: lum, width: hw, height: hh)
        guard stars.count >= 3 else { return nil }
        let pairs = TriangleMatcher.correspondences(source: stars, target: referenceStars)
        guard let half = TransformSolver.solve(source: stars, target: referenceStars, pairs: pairs,
                                               minMatches: minMatches, inlierTolerance: inlierTolerance)
        else { return nil }
        let rgb = displayRGB(frame, minRows: minRows)
        guard rgb.channels == referenceChannels else { return nil }
        var scale: Float = 1.0
        if scaleNormalization {
            let ins = TransformSolver.inliers(half, source: stars, target: referenceStars,
                                              pairs: pairs, tolerance: inlierTolerance)
            scale = Self.scaleFactor(fluxPairs: ins.map { (sub: stars[$0.source].flux, ref: referenceStars[$0.target].flux) })
        }
        let weight = frameWeight(stars: stars.count, sigma: sigma * scale)   // σ·s: scaling amplifies noise too — weight must see post-scale noise
        // R4/R5: background fit removed from register — see levelingModels (fit on WARPED frame).
        return RegisteredFrame(transform: half, rgb: rgb, weight: weight, scale: scale)
    }

    /// Produce BOTH domain-matched leveling models for a WARPED (reference-aligned) frame:
    /// the SUB model (fit from the warped frame's tile samples) and the REF model (fit from
    /// the STORED seed tile samples) — BOTH solved over the SAME masked tile subset, so the
    /// two least-squares fits share a spatial domain. This is the R5 fix: a full-frame seed
    /// fit vs a masked sub fit over a non-polynomial sky gave different coeffs, injecting a
    /// spurious `surfSub − surfRef` differential even when the sub was identical to the seed
    /// over the covered region. Matching the domain drives that injected error to ~0.
    ///
    /// Returns nil when normalization is off OR the reference samples are absent (off-path
    /// parity: caller applies no leveling). Per-channel nil coeffs propagate as today
    /// (GradientLeveler treats a nil channel as passthrough).
    ///
    /// Pure and lock-free: reads only `normalization` (immutable) + `referenceBackgroundSamples`,
    /// which is set at seed (serial, before the concurrent register/warp phase per the batch
    /// contract) and treated as immutable for the batch — same contract as `referenceStars`.
    /// The live path calls this inside `processLocked` (under the lock).
    public func levelingModels(image: AstroImage, mask: [Float])
        -> (sub: BackgroundExtraction.BackgroundModel, ref: BackgroundExtraction.BackgroundModel)? {
        guard normalization, let refSamples = referenceBackgroundSamples else { return nil }
        let deg = Self.backgroundDegree
        let w = image.width, h = image.height
        let subSamples = BackgroundExtraction.tileSamples(image)
        let included = BackgroundExtraction.maskGatedTileIndices(
            width: w, height: h, mask: mask)
        let subX = included.map { subSamples.x[$0] }
        let subY = included.map { subSamples.y[$0] }
        let refX = included.map { refSamples.x[$0] }
        let refY = included.map { refSamples.y[$0] }
        var subCoeffs = [[Double]?](repeating: nil, count: max(image.channels, subSamples.v.count))
        var refCoeffs = [[Double]?](repeating: nil, count: subCoeffs.count)
        for c in 0..<subCoeffs.count {
            if c < subSamples.v.count, let sv = subSamples.v[c] {
                let vals = included.map { sv[$0] }
                subCoeffs[c] = BackgroundExtraction.solveModel(x: subX, y: subY, v: vals, degree: deg)
            }
            if c < refSamples.v.count, let rv = refSamples.v[c] {
                let vals = included.map { rv[$0] }
                refCoeffs[c] = BackgroundExtraction.solveModel(x: refX, y: refY, v: vals, degree: deg)
            }
        }
        let sub = BackgroundExtraction.BackgroundModel(degree: deg, width: w, height: h, coeffPerChannel: subCoeffs)
        let ref = BackgroundExtraction.BackgroundModel(degree: deg, width: w, height: h, coeffPerChannel: refCoeffs)
        return (sub, ref)
    }

    /// Warp a registered frame to reference alignment. Pure, concurrent-safe.
    public func warp(_ reg: RegisteredFrame, minRows: Int) -> (image: AstroImage, mask: [Float]) {
        Warp.apply(reg.rgb, transform: reg.transform.liftedToFullResolution(), minRows: minRows)
    }

    /// Accumulate a warped frame into the shared stack under the engine lock.
    /// Bumps acceptedCount. Rejection filtering runs here (serial), preserving any
    /// stateful RejectionMethod. Call from the single serial consumer.
    public func commit(image: AstroImage, mask: [Float], frameWeight: Float = 1.0, scale: Float = 1.0,
                       leveling: (sub: BackgroundExtraction.BackgroundModel,
                                  ref: BackgroundExtraction.BackgroundModel)? = nil, minRows: Int) {
        lock.withLock {
            guard let accumulator else { return }
            // Scaling is fused into leveling with a per-pixel reference-background pivot.
            // When the leveling pair is nil (per-frame fit failure) NO scaling happens for
            // this frame — consistent with the gate. Note: the weight was computed with σ·s
            // at register time; a rare per-frame fit failure leaves that weight slightly
            // conservative (an unscaled frame carrying a scaled-noise weight) — acceptable.
            var frame = image
            if let pair = leveling {
                frame = GradientLeveler.apply(image, subModel: pair.sub, refModel: pair.ref, scale: scale, minRows: minRows)
            }
            let cleaned = rejection.apply(frame, mask: mask)
            accumulator.add(cleaned, mask: mask, frameWeight: frameWeight, minRows: minRows)
            acceptedCount += 1
            consecutiveNoTransform = 0
        }
    }

    /// Record a batch rejection (bumps rejectedCount) under the lock.
    public func commitRejection() {
        lock.withLock { rejectedCount += 1 }
    }
}
