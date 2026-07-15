// Tests/LiveAstroCoreTests/ScaleNormalizationEngineTests.swift
import XCTest
@testable import LiveAstroCore

final class ScaleNormalizationEngineTests: XCTestCase {
    // Gray CFA starfield — same pattern as StackEngineStagedTests.
    func cfaFrame(width: Int = 512, height: Int = 512,
                  stars: [(x: Double, y: Double)], amp: Float = 0.8,
                  bg: Float = 0.05,
                  name: String = "test.fit") -> RawFrame {
        var px = [Float](repeating: bg, count: width * height)
        for s in stars {
            for y in max(0, Int(s.y) - 8)...min(height - 1, Int(s.y) + 8) {
                for x in max(0, Int(s.x) - 8)...min(width - 1, Int(s.x) + 8) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += amp * Float(exp(-(dx * dx + dy * dy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }

    // 0.7× dimmed version: signal above background is scaled by factor.
    func dimmedFrame(from frame: RawFrame, factor: Float, bg: Float = 0.05) -> RawFrame {
        let px = frame.image.pixels.map { bg + ($0 - bg) * factor }
        let img = AstroImage(width: frame.image.width, height: frame.image.height,
                             channels: frame.image.channels, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: frame.bayerPattern, bottomUp: frame.bottomUp,
                        timestamp: frame.timestamp, sourceName: frame.sourceName)
    }

    let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    // MARK: - register scale

    func testRegisterScaleOneWhenOff() {
        let engine = StackEngine(scaleNormalization: false)
        let seedFrame = cfaFrame(stars: field)
        XCTAssertTrue(engine.seedReference(seedFrame, minRows: .max))
        let shifted = field.map { (x: $0.x + 3.0, y: $0.y - 2.0) }
        let sub = cfaFrame(stars: shifted, amp: 0.56)   // 0.7× dimmed
        let reg = engine.register(sub, minRows: .max)
        XCTAssertNotNil(reg)
        XCTAssertEqual(reg!.scale, 1.0, accuracy: 1e-6)
    }

    func testRegisterComputesScaleWhenOn() {
        // Sub signal is 0.7× the seed signal above background → scale factor ≈ 1/0.7 ≈ 1.43.
        // Scaling is gated behind leveling → must enable normalization too.
        let engine = StackEngine(normalization: true, scaleNormalization: true)
        let seedFrame = cfaFrame(stars: field, amp: 0.8)
        XCTAssertTrue(engine.seedReference(seedFrame, minRows: .max))
        let shifted = field.map { (x: $0.x + 3.0, y: $0.y - 2.0) }
        let sub = cfaFrame(stars: shifted, amp: 0.8 * 0.7)   // 70% of seed amplitude
        let reg = engine.register(sub, minRows: .max)
        XCTAssertNotNil(reg)
        XCTAssertGreaterThan(reg!.scale, 1.0)
        // Expect roughly 1/0.7 ≈ 1.43; allow ±0.3 tolerance for RANSAC inlier noise
        XCTAssertEqual(reg!.scale, 1.0 / 0.7, accuracy: 0.3)
    }

    // MARK: - off-path byte identity

    func testOffPathByteIdentical() {
        // Scale normalization OFF: two engines with identical inputs produce identical stacks
        // (regression guard that the off-path doesn't accidentally apply scaling).
        let seedFrame = cfaFrame(stars: field)
        let shifted = field.map { (x: $0.x + 2.1, y: $0.y - 1.5) }
        let sub = cfaFrame(stars: shifted)

        func buildOff() -> [Float] {
            let engine = StackEngine(scaleNormalization: false)
            XCTAssertTrue(engine.seedReference(seedFrame, minRows: .max))
            let reg = engine.register(sub, minRows: .max)
            XCTAssertNotNil(reg)
            XCTAssertEqual(reg!.scale, 1.0, accuracy: 1e-6)   // off → scale always 1.0
            let w = engine.warp(reg!, minRows: .max)
            engine.commit(image: w.image, mask: w.mask, scale: reg!.scale, minRows: .max)
            return engine.currentStack()!.pixels
        }

        let a = buildOff()
        let b = buildOff()
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x, y, accuracy: 1e-6)
        }
    }

    // MARK: - dim sub restoration

    func testDimSubRestoredTowardReference() {
        // Seed normal (amp 0.8); stack 9 dimmed subs (amp 0.56 = 0.7×).
        // With scaling ON the dimmed subs are boosted → master peak is closer to the seed peak
        // than when scaling is OFF (where the dimmed subs pull the mean down).
        let seedFrame = cfaFrame(stars: field, amp: 0.8)
        let shifted = field.map { (x: $0.x + 2.5, y: $0.y - 1.8) }

        // The "reference" peak: a solo seed-only engine (1 frame, no subs).
        let refEngine = StackEngine()
        XCTAssertTrue(refEngine.seedReference(seedFrame, minRows: .max))
        let refStack = refEngine.currentStack()!

        func buildStack(scaleOn: Bool) -> AstroImage {
            // Scaling is gated behind leveling → enable normalization when scaling is on.
            let engine = StackEngine(normalization: scaleOn, scaleNormalization: scaleOn)
            XCTAssertTrue(engine.seedReference(seedFrame, minRows: .max))
            for i in 0..<9 {
                let sub = cfaFrame(stars: shifted, amp: 0.8 * 0.7, name: "sub\(i).fit")
                if let reg = engine.register(sub, minRows: .max) {
                    let w = engine.warp(reg, minRows: .max)
                    // Scaling is fused into leveling → must pass the leveling models for
                    // scaling to take effect (nil when leveling is off, giving the OFF path).
                    let lv = engine.levelingModels(image: w.image, mask: w.mask)
                    engine.commit(image: w.image, mask: w.mask, scale: reg.scale, leveling: lv, minRows: .max)
                }
            }
            return engine.currentStack()!
        }

        let offStack = buildStack(scaleOn: false)
        let onStack  = buildStack(scaleOn: true)

        // Find the peak luminance pixel (summed over channels) near the first star (60, 80).
        func peakNear(img: AstroImage, cx: Int, cy: Int, radius: Int = 12) -> Float {
            let plane = img.width * img.height
            var best: Float = 0
            for y in max(0, cy - radius)...min(img.height - 1, cy + radius) {
                for x in max(0, cx - radius)...min(img.width - 1, cx + radius) {
                    let v = (0..<img.channels).reduce(Float(0)) { $0 + img.pixels[$1 * plane + y * img.width + x] }
                    if v > best { best = v }
                }
            }
            return best
        }

        let refPeak = peakNear(img: refStack, cx: 60, cy: 80)
        let offPeak = peakNear(img: offStack, cx: 60, cy: 80)
        let onPeak  = peakNear(img: onStack,  cx: 60, cy: 80)

        // OFF: dimmed subs pull the mean below the seed peak (offPeak < refPeak).
        XCTAssertLessThan(offPeak, refPeak, "OFF: dimmed subs should pull peak below reference")
        // ON: scaling boosts subs toward seed brightness → peak closer to refPeak.
        let offDist = abs(offPeak - refPeak)
        let onDist  = abs(onPeak  - refPeak)
        XCTAssertLessThan(onDist, offDist,
            "Scaling ON (onPeak=\(onPeak)) should be closer to refPeak=\(refPeak) than OFF (offPeak=\(offPeak))")
    }

    // MARK: - σ·s weighting

    func testWeightSeesPostScaleNoise() {
        // P1-4 new shape: RegisteredFrame carries stars+sigma+scale (weight is computed by the
        // caller from the APPLIED scale). A dimmed sub weighted σ·s (scaling ON, applied) is
        // LOWER than σ·1 (scaling OFF), because s > 1 inflates the effective noise term.
        let seedFrame = cfaFrame(stars: field, amp: 0.8)
        let shifted = field.map { (x: $0.x + 3.0, y: $0.y - 2.0) }
        let sub = cfaFrame(stars: shifted, amp: 0.8 * 0.7)

        let engineOff = StackEngine(frameWeighting: true, scaleNormalization: false)
        XCTAssertTrue(engineOff.seedReference(seedFrame, minRows: .max))
        let regOff = engineOff.register(sub, minRows: .max)
        XCTAssertNotNil(regOff)
        // scaling off → scale is 1.0 → weight uses σ·1
        let weightOff = engineOff.frameWeight(stars: regOff!.stars, sigma: regOff!.sigma * regOff!.scale)

        let engineOn = StackEngine(frameWeighting: true, normalization: true, scaleNormalization: true)
        XCTAssertTrue(engineOn.seedReference(seedFrame, minRows: .max))
        let regOn = engineOn.register(sub, minRows: .max)
        XCTAssertNotNil(regOn)
        // The scale is APPLIED (full CFA field levels cleanly), so weight uses σ·s.
        let wOn = engineOn.warp(regOn!, minRows: .max)
        let lvOn = engineOn.levelingModels(image: wOn.image, mask: wOn.mask)
        XCTAssertNotNil(lvOn)
        XCTAssertTrue(GradientLeveler.scalingApplies(subModel: lvOn!.sub, refModel: lvOn!.ref,
                                                     channels: wOn.image.channels),
                      "the full CFA field should level cleanly so the scale is applied")
        let weightOn = engineOn.frameWeight(stars: regOn!.stars, sigma: regOn!.sigma * regOn!.scale)

        // scale > 1 → σ·s > σ → noise is judged higher → weight is lower
        XCTAssertGreaterThan(regOn!.scale, 1.0)
        XCTAssertLessThan(weightOn, weightOff,
            "Applied-scale weight (\(weightOn)) should be < unscaled weight (\(weightOff)) for a dimmed sub")
    }

    /// P1-4 core fix: when scaling is SUPPRESSED (an unlevelable channel in the leveling pair),
    /// the frame is stacked UNSCALED, so its weight must be the σ-only weight — NOT σ·s. Before
    /// the fix, weight was computed at register with σ·s regardless, so a scale-0.5 frame whose
    /// scaling was later suppressed was over-weighted (σ·0.5 → up to 4×).
    func testSuppressedScaleWeightsSigmaOnly() {
        let engine = StackEngine(frameWeighting: true)
        engine.setWeightBaselineForTesting(stars: 100, sigma: 0.02)
        let channels = 3
        let scale: Float = 0.5
        let sigma: Float = 0.02

        // Leveling pair with ONE unlevelable channel (ch0 sub coeff nil) → scalingApplies false.
        let suppressedSub = BackgroundExtraction.BackgroundModel(
            degree: 1, width: 4, height: 4, coeffPerChannel: [nil, [0, 0, 0], [0, 0, 0]])
        let suppressedRef = BackgroundExtraction.BackgroundModel(
            degree: 1, width: 4, height: 4, coeffPerChannel: [[0, 0, 0], [0, 0, 0], [0, 0, 0]])
        XCTAssertFalse(GradientLeveler.scalingApplies(subModel: suppressedSub, refModel: suppressedRef, channels: channels))
        let effectiveSuppressed: Float = GradientLeveler.scalingApplies(subModel: suppressedSub, refModel: suppressedRef, channels: channels) ? scale : 1.0
        XCTAssertEqual(effectiveSuppressed, 1.0)
        let weightSuppressed = engine.frameWeight(stars: 100, sigma: sigma * effectiveSuppressed)

        // The σ-only reference weight (what a correctly-unscaled frame must get).
        let weightSigmaOnly = engine.frameWeight(stars: 100, sigma: sigma)
        XCTAssertEqual(weightSuppressed, weightSigmaOnly, accuracy: 1e-6,
                       "a scale-suppressed frame must be weighted σ·1, not σ·s")

        // A full coeff pair → scale IS applied → weight uses σ·s (different from σ-only).
        let fullSub = BackgroundExtraction.BackgroundModel(
            degree: 1, width: 4, height: 4, coeffPerChannel: [[0, 0, 0], [0, 0, 0], [0, 0, 0]])
        XCTAssertTrue(GradientLeveler.scalingApplies(subModel: fullSub, refModel: suppressedRef, channels: channels))
        let effectiveFull: Float = GradientLeveler.scalingApplies(subModel: fullSub, refModel: suppressedRef, channels: channels) ? scale : 1.0
        XCTAssertEqual(effectiveFull, scale)
        let weightFull = engine.frameWeight(stars: 100, sigma: sigma * effectiveFull)
        // s = 0.5 < 1 → σ·0.5 < σ → LOWER noise term → HIGHER weight (clamped at wHi 4)
        XCTAssertGreaterThan(weightFull, weightSigmaOnly,
                             "an APPLIED scale<1 raises the weight (σ·s < σ), distinct from the suppressed case")
    }

    // MARK: - reset on reseed

    func testResetOnReseed() {
        // Seed a BRIGHT field → reseed → seed a NORMAL field → commit an identical normal sub.
        // With correct reset, the master pixels after commit should be near-unchanged from the
        // normal seed (the bright reference must NOT bleed into the second session).
        let brightField = cfaFrame(stars: field, amp: 0.9, bg: 0.2)
        let normalSeed  = cfaFrame(stars: field, amp: 0.8, bg: 0.05)
        let shifted     = field.map { (x: $0.x + 2.0, y: $0.y - 1.5) }
        let normalSub   = cfaFrame(stars: shifted, amp: 0.8, bg: 0.05)

        let engine = StackEngine(normalization: true, scaleNormalization: true)
        XCTAssertTrue(engine.seedReference(brightField, minRows: .max))
        engine.reseed()
        XCTAssertTrue(engine.seedReference(normalSeed, minRows: .max))

        let reg = engine.register(normalSub, minRows: .max)
        XCTAssertNotNil(reg)
        let lv = engine.levelingModels(image: engine.warp(reg!, minRows: .max).image,
                                       mask: engine.warp(reg!, minRows: .max).mask)
        let w = engine.warp(reg!, minRows: .max)
        engine.commit(image: w.image, mask: w.mask, scale: reg!.scale, leveling: lv, minRows: .max)

        // The normal sub's scale against the normal seed should be close to 1 (same brightness).
        XCTAssertEqual(reg!.scale, 1.0, accuracy: 0.3)

        // The stack should be close to the seed brightness (sky around the edge should be
        // roughly the normal background level, not the bright one).
        let stack = engine.currentStack()!
        // Sample a sky pixel far from any star — use top-left corner area
        let skyVal = stack.pixels[0]   // top-left, far from any star (which starts at 60.2,80.5)
        XCTAssertLessThan(skyVal, 0.25, "Sky should be near normal background after reseed, not bright one")
    }

    // MARK: - gate regression

    /// The gate: normalization OFF + scaleNormalization ON must behave as scaling OFF.
    /// reg.scale == 1.0 (no scale computed) and the master is byte-equal to a both-off engine.
    func testScalingGatedOffWhenLevelingOff() {
        let seedFrame = cfaFrame(stars: field)
        let shifted = field.map { (x: $0.x + 2.1, y: $0.y - 1.5) }
        let sub = cfaFrame(stars: shifted, amp: 0.8 * 0.7)   // dimmed — would scale if ungated

        func build(normalization: Bool, scaleNormalization: Bool) -> (scale: Float, pixels: [Float]) {
            let engine = StackEngine(normalization: normalization, scaleNormalization: scaleNormalization)
            XCTAssertTrue(engine.seedReference(seedFrame, minRows: .max))
            let reg = engine.register(sub, minRows: .max)!
            let lv = engine.levelingModels(image: engine.warp(reg, minRows: .max).image,
                                           mask: engine.warp(reg, minRows: .max).mask)
            let w = engine.warp(reg, minRows: .max)
            engine.commit(image: w.image, mask: w.mask, scale: reg.scale, leveling: lv, minRows: .max)
            return (reg.scale, engine.currentStack()!.pixels)
        }

        let gated = build(normalization: false, scaleNormalization: true)   // scaling requested but gated off
        let bothOff = build(normalization: false, scaleNormalization: false)

        XCTAssertEqual(gated.scale, 1.0, accuracy: 1e-6, "gate must force scale to 1.0 when leveling is off")
        XCTAssertEqual(gated.pixels.count, bothOff.pixels.count)
        for (g, o) in zip(gated.pixels, bothOff.pixels) {
            XCTAssertEqual(g, o, accuracy: 1e-6, "gated-off master must byte-equal both-off master")
        }
    }

    /// REGRESSION for the PROVEN finding (moonrise regime): seed with LOW background, subs with
    /// HIGHER background + dimmer stars (transparency loss). Leveling + scaling ON.
    /// The fused per-pixel-surface pivot levels the sub's raised sky onto the seed's sky and
    /// scales the leveled signal about that — so the master's sky stays near the seed's sky
    /// with NO injected (bg_sub − bg₀)(s − 1) pedestal. The OLD scalar-pivot code (SignalScaler
    /// about the seed's scalar bg AFTER leveling — or worse, with leveling off) injected exactly
    /// that pedestal, pushing the sky up. Star amplitude is still restored toward the seed.
    func testMoonriseRegimeNoPedestal() {
        let seedBg: Float = 0.05
        let subBg: Float = 0.12   // moonrise: higher sky background
        let seedFrame = cfaFrame(stars: field, amp: 0.8, bg: seedBg)

        let engine = StackEngine(normalization: true, scaleNormalization: true)
        XCTAssertTrue(engine.seedReference(seedFrame, minRows: .max))

        let shifted = field.map { (x: $0.x + 2.5, y: $0.y - 1.8) }
        for i in 0..<9 {
            // dimmer stars (0.7×) AND a raised background — a transparency-loss/moonrise sub.
            let sub = cfaFrame(stars: shifted, amp: 0.8 * 0.7, bg: subBg, name: "moon\(i).fit")
            if let reg = engine.register(sub, minRows: .max) {
                let w = engine.warp(reg, minRows: .max)
                let lv = engine.levelingModels(image: w.image, mask: w.mask)
                let ws = engine.committedWeightAndScale(reg: reg, leveling: lv, channels: w.image.channels)
                engine.commit(image: w.image, mask: w.mask, frameWeight: ws.weight,
                              scale: ws.scale, leveling: lv, minRows: .max)
            }
        }

        let stack = engine.currentStack()!

        // Sky median far from stars: sample a coarse grid of pixels away from the star field
        // and take the median per channel-summed luminance divided by channels ≈ per-channel sky.
        let plane = stack.width * stack.height
        func farFromStars(_ x: Int, _ y: Int) -> Bool {
            for s in shifted {
                let dx = Double(x) - s.x, dy = Double(y) - s.y
                if dx * dx + dy * dy < 30 * 30 { return false }
            }
            return true
        }
        var skySamples: [Float] = []
        var yy = 20
        while yy < stack.height - 20 {
            var xx = 20
            while xx < stack.width - 20 {
                if farFromStars(xx, yy) {
                    // per-channel average at this pixel
                    let v = (0..<stack.channels).reduce(Float(0)) { $0 + stack.pixels[$1 * plane + yy * stack.width + xx] } / Float(stack.channels)
                    skySamples.append(v)
                }
                xx += 17
            }
            yy += 17
        }
        skySamples.sort()
        let skyMedian = skySamples[skySamples.count / 2]

        // The master sky must stay near the SEED's sky (seedBg), NOT be pushed up toward subBg
        // or above by a (bg_sub − bg₀)(s − 1) pedestal. The seed frame contributes its own sky
        // (0.05) to the mean; leveled+scaled subs contribute ~0.05 too. Tight tolerance around
        // the seed level. (Pre-fix scalar-pivot: pedestal ≈ (0.12−0.05)(1.43−1) ≈ 0.030 on each
        // sub → master sky pulled up measurably above this bound.)
        XCTAssertEqual(skyMedian, seedBg, accuracy: 0.02,
            "master sky (\(skyMedian)) must stay near seed sky \(seedBg) — no injected pedestal")

        // Star amplitude is restored: the peak near a star exceeds a plain unscaled dim stack's
        // peak. Compare against a leveling-only (no scaling) engine.
        func peakNear(_ img: AstroImage, cx: Int, cy: Int, radius: Int = 12) -> Float {
            var best: Float = 0
            for y in max(0, cy - radius)...min(img.height - 1, cy + radius) {
                for x in max(0, cx - radius)...min(img.width - 1, cx + radius) {
                    let v = (0..<img.channels).reduce(Float(0)) { $0 + img.pixels[$1 * plane + y * img.width + x] }
                    if v > best { best = v }
                }
            }
            return best
        }

        let levelOnly = StackEngine(normalization: true, scaleNormalization: false)
        XCTAssertTrue(levelOnly.seedReference(seedFrame, minRows: .max))
        for i in 0..<9 {
            let sub = cfaFrame(stars: shifted, amp: 0.8 * 0.7, bg: subBg, name: "moonL\(i).fit")
            if let reg = levelOnly.register(sub, minRows: .max) {
                let w = levelOnly.warp(reg, minRows: .max)
                let lv = levelOnly.levelingModels(image: w.image, mask: w.mask)
                let ws = levelOnly.committedWeightAndScale(reg: reg, leveling: lv, channels: w.image.channels)
                levelOnly.commit(image: w.image, mask: w.mask, frameWeight: ws.weight,
                                 scale: ws.scale, leveling: lv, minRows: .max)
            }
        }
        let scaledPeak = peakNear(stack, cx: Int(shifted[0].x), cy: Int(shifted[0].y))
        let unscaledPeak = peakNear(levelOnly.currentStack()!, cx: Int(shifted[0].x), cy: Int(shifted[0].y))
        XCTAssertGreaterThan(scaledPeak, unscaledPeak,
            "scaling ON must restore star amplitude above leveling-only (\(scaledPeak) vs \(unscaledPeak))")
    }
}
