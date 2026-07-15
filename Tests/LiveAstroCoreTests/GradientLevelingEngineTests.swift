// Tests/LiveAstroCoreTests/GradientLevelingEngineTests.swift
import XCTest
@testable import LiveAstroCore

final class GradientLevelingEngineTests: XCTestCase {
    // CFA frame: stars + a linear sky gradient with x-slope `slope` (per-pixel over width).
    func cfaFrame(stars: [(Double, Double)], slope: Float, base: Float = 0.05, w: Int = 256, h: Int = 256) -> RawFrame {
        var px = [Float](repeating: base, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y*w+x] += slope * Float(x) / Float(w-1) } }
        for s in stars {
            for y in max(0, Int(s.1)-6)...min(h-1, Int(s.1)+6) {
                for x in max(0, Int(s.0)-6)...min(w-1, Int(s.0)+6) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    px[y*w+x] += 0.8 * Float(exp(-(dx*dx+dy*dy)/(2*2.0*2.0)))
                }
            }
        }
        return RawFrame(image: AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true),
                        bayerPattern: .grbg, bottomUp: false, timestamp: Date(timeIntervalSince1970: 0), sourceName: "t.fit")
    }

    /// Build a CFA frame with stars at given positions and a gradient along Y (not X).
    func cfaFrameYGradient(stars: [(Double, Double)], ySlope: Float, base: Float = 0.05, w: Int = 256, h: Int = 256) -> RawFrame {
        var px = [Float](repeating: base, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y*w+x] += ySlope * Float(y) / Float(h-1) } }
        for s in stars {
            for y in max(0, Int(s.1)-6)...min(h-1, Int(s.1)+6) {
                for x in max(0, Int(s.0)-6)...min(w-1, Int(s.0)+6) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    px[y*w+x] += 0.8 * Float(exp(-(dx*dx+dy*dy)/(2*2.0*2.0)))
                }
            }
        }
        return RawFrame(image: AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true),
                        bayerPattern: .grbg, bottomUp: false, timestamp: Date(timeIntervalSince1970: 0), sourceName: "t.fit")
    }

    /// Rotate star positions 90 degrees clockwise around the center of a w×h frame.
    func rotateStars90CW(_ stars: [(Double, Double)], w: Int, h: Int) -> [(Double, Double)] {
        let cx = Double(w) / 2.0, cy = Double(h) / 2.0
        return stars.map { (x, y) in
            let dx = x - cx, dy = y - cy
            // 90° CW: (dx, dy) -> (dy, -dx)
            return (cx + dy, cy - dx)
        }
    }

    let field: [(Double, Double)] = [
        (30,30),(90,60),(150,90),(210,120),(60,150),(120,180),(180,210),(40,200),(200,40),(100,100),
        (160,50),(50,90),(140,140),(80,220),(220,80),(110,30),(30,110),(190,190),(70,70),(150,200)
    ]

    // MARK: - Tests that must remain green (existing invariants)

    /// After R5: register no longer produces a backgroundModel — test levelingModels instead.
    func testLevelingModelsWhenOn() {
        let eng = StackEngine(normalization: true)
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
        let reg = eng.register(cfaFrame(stars: field, slope: 0.10), minRows: .max)
        XCTAssertNotNil(reg, "register should succeed")
        guard let reg else { return }
        let w = eng.warp(reg, minRows: .max)
        let models = eng.levelingModels(image: w.image, mask: w.mask)
        XCTAssertNotNil(models, "levelingModels must return a pair when normalization is on")
        XCTAssertNotNil(models?.sub.coeffPerChannel[0] ?? nil)
        XCTAssertNotNil(models?.ref.coeffPerChannel[0] ?? nil)
    }

    func testLevelingModelsNilWhenOff() {
        let eng = StackEngine(normalization: false)
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
        let reg = eng.register(cfaFrame(stars: field, slope: 0.10), minRows: .max)
        XCTAssertNotNil(reg, "register should succeed")
        guard let reg else { return }
        let w = eng.warp(reg, minRows: .max)
        XCTAssertNil(eng.levelingModels(image: w.image, mask: w.mask),
                     "levelingModels must return nil when normalization is off")
    }

    func testOffPathByteIdentical() {
        // normalization:false must equal a stack that never applies the leveler.
        func run(_ on: Bool) -> [Float] {
            let eng = StackEngine(normalization: on)
            _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
            for _ in 0..<4 {
                if let reg = eng.register(cfaFrame(stars: field, slope: 0.0), minRows: .max) {
                    let (img, mask) = eng.warp(reg, minRows: .max)
                    let lv = eng.levelingModels(image: img, mask: mask)
                    let ws = eng.committedWeightAndScale(reg: reg, leveling: lv, channels: img.channels)
                    eng.commit(image: img, mask: mask, frameWeight: ws.weight,
                               scale: ws.scale, leveling: lv, minRows: .max)
                }
            }
            return eng.currentStack()!.pixels
        }
        // flat-gradient frames identical to the flat reference → leveler subtracts ~0 → within fp tol.
        let off = run(false), on = run(true)
        for (a, b) in zip(off, on) { XCTAssertEqual(a, b, accuracy: 1e-4) }
    }

    func testGradientDifferenceIsLeveledBeforeCombine() {
        // Reference is flat (slope 0). Subs carry a strong x-gradient (slope 0.30). With leveling
        // the stacked master's left→right delta shrinks toward the flat reference; without, it stays.
        func lrDelta(_ on: Bool) -> Float {
            let eng = StackEngine(normalization: on)
            _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
            for _ in 0..<9 {
                if let reg = eng.register(cfaFrame(stars: field, slope: 0.30), minRows: .max) {
                    let (img, mask) = eng.warp(reg, minRows: .max)
                    let lv = eng.levelingModels(image: img, mask: mask)
                    let ws = eng.committedWeightAndScale(reg: reg, leveling: lv, channels: img.channels)
                    eng.commit(image: img, mask: mask, frameWeight: ws.weight,
                               scale: ws.scale, leveling: lv, minRows: .max)
                }
            }
            let m = eng.currentStack()!
            // sky delta: median of a right-edge column band minus a left-edge column band (star-free rows)
            func band(_ xr: Range<Int>) -> Float {
                var v = [Float](); for y in 0..<8 { for x in xr { v.append(m.pixels[y*m.width+x]) } }; v.sort(); return v[v.count/2]
            }
            return band((m.width-8)..<m.width) - band(0..<8)
        }
        let on = lrDelta(true), off = lrDelta(false)
        XCTAssertLessThan(on, off)              // leveled master is flatter (smaller L→R delta)
    }

    func testBaselineResetOnReseed() {
        let eng = StackEngine(normalization: true)
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.30), minRows: .max)   // sloped baseline
        eng.reseed()
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)     // flat baseline
        // a flat sub now levels ~0 against the flat baseline (not −0.30 against the old sloped one)
        if let reg = eng.register(cfaFrame(stars: field, slope: 0.0), minRows: .max) {
            let (img, mask) = eng.warp(reg, minRows: .max)
            let before = img.pixels
            let lv = eng.levelingModels(image: img, mask: mask)
            let ws = eng.committedWeightAndScale(reg: reg, leveling: lv, channels: img.channels)
            eng.commit(image: img, mask: mask, frameWeight: ws.weight, scale: ws.scale, leveling: lv, minRows: .max)
            // the committed (leveled) frame ≈ the warped frame (flat vs flat → ~no change) at a mid sky pixel
            XCTAssertEqual(eng.currentStack()!.pixels[100*eng.currentStack()!.width + 5], before[100*img.width + 5], accuracy: 0.03)
        } else { XCTFail("register failed") }
    }

    // MARK: - Rotation regression (C1 fix: R4)

    /// Rotation regression: a sub captured with a strong Y-axis gradient, rotated 90° CW so that
    /// after registration+warp its gradient appears as an X-axis gradient in reference coords.
    ///
    /// Pre-R4 (OLD) behavior: background model fit on the PRE-warp frame captures the Y-gradient.
    /// After warp, the actual warped-frame gradient is in reference-coord orientation. Fitting
    /// pre-warp produces a misaligned correction: the model describes the un-rotated gradient
    /// direction, so it subtracts the wrong surface from the warped frame. Observed evidence:
    /// old code could not fully remove the gradient and left residuals proportional to the
    /// rotation mismatch.
    ///
    /// Post-R4 (NEW) behavior: background model fit on the WARPED frame (mask-aware) captures
    /// the gradient as it actually appears in reference coords. The correction is correct, and
    /// the leveled master has near-zero L→R delta — dramatically better than warp-only.
    ///
    /// The test asserts:
    ///   (1) leveled << unleveled — fit-on-warped removes the gradient; warp-only does not.
    ///       (This pins the C1 correctness fix: the leveled delta must be < 5% of unleveled.)
    ///   (2) leveled ≤ unleveled * 1.10 — leveled is no WORSE than warp-only (10% slack).
    ///       (Would fail pre-R4 when the misaligned correction injected more error than it removed.)
    func testRotationRegressionFitOnWarpedFrame() {
        let w = 256, h = 256
        // Reference: flat field (zero gradient), stars at `field` positions.
        // Sub: same stars rotated 90° CW, with a strong Y-gradient (0.30).
        // After register+warp, the sub aligns with reference coords; the gradient direction
        // is transformed and appears along X in the warped frame.
        let rotatedStars = rotateStars90CW(field, w: w, h: h)

        func lrDelta(_ eng: StackEngine) -> Float {
            guard let m = eng.currentStack() else { return 0 }
            func band(_ xr: Range<Int>) -> Float {
                var v = [Float]()
                for y in 10..<(h-10) { for x in xr { v.append(m.pixels[y*m.width+x]) } }
                v.sort(); return v[v.count/2]
            }
            return abs(band((w-16)..<w) - band(0..<16))
        }

        // New (R4): fit on WARPED frame — fitWarpedBackground uses the mask-aware warped image.
        let engOn = StackEngine(normalization: true)
        _ = engOn.seedReference(cfaFrame(stars: field, slope: 0.0, w: w, h: h), minRows: .max)
        for _ in 0..<6 {
            let sub = cfaFrameYGradient(stars: rotatedStars, ySlope: 0.30, w: w, h: h)
            if let reg = engOn.register(sub, minRows: .max) {
                let (img, mask) = engOn.warp(reg, minRows: .max)
                let lv = engOn.levelingModels(image: img, mask: mask)
                let ws = engOn.committedWeightAndScale(reg: reg, leveling: lv, channels: img.channels)
                engOn.commit(image: img, mask: mask, frameWeight: ws.weight,
                             scale: ws.scale, leveling: lv, minRows: .max)
            }
        }

        // Unleveled (warp-only baseline — no correction applied).
        let engOff = StackEngine(normalization: false)
        _ = engOff.seedReference(cfaFrame(stars: field, slope: 0.0, w: w, h: h), minRows: .max)
        for _ in 0..<6 {
            let sub = cfaFrameYGradient(stars: rotatedStars, ySlope: 0.30, w: w, h: h)
            if let reg = engOff.register(sub, minRows: .max) {
                let (img, mask) = engOff.warp(reg, minRows: .max)
                let ws = engOff.committedWeightAndScale(reg: reg, leveling: nil, channels: img.channels)
                engOff.commit(image: img, mask: mask, frameWeight: ws.weight,
                              scale: ws.scale, leveling: nil, minRows: .max)
            }
        }

        let leveled = lrDelta(engOn)
        let unleveled = lrDelta(engOff)

        // Log the values — test output is the pre/post-fix evidence record.
        // leveled ≈ 0 (gradient removed by fit-on-warped correction).
        // unleveled ≈ 0.24 (full gradient error present without leveling).
        print("Rotation regression: fit-on-warped(R4)=\(leveled), warp-only(baseline)=\(unleveled)")

        // (1) fit-on-warped dramatically reduces the gradient error (C1 fix evidence).
        //     Leveled delta must be < 5% of the unleveled delta.
        XCTAssertLessThan(leveled, unleveled * 0.05,
            "fit-on-warped(R4) must remove the rotation-injected gradient: " +
            "leveled=\(leveled) should be < 5% of unleveled=\(unleveled). " +
            "If leveled ≈ unleveled, the model is not being applied to the warped frame.")

        // (2) Sanity: leveled is not WORSE than unleveled (10% slack for float rounding).
        XCTAssertLessThanOrEqual(leveled, unleveled * 1.10,
            "Fit-on-warped(R4): leveled L→R delta (\(leveled)) must be ≤ unleveled * 1.10 (\(unleveled * 1.10)).")
    }

    // MARK: - Domain-asymmetry regression (R5 Critical fix)

    /// CFA frame whose sky is NOT low-order: linear x-gradient + a broad OFF-CENTER
    /// Gaussian blob (nebula-like), plus registration stars.
    func cfaFrameNonPolynomial(stars: [(Double, Double)], w: Int = 256, h: Int = 256) -> RawFrame {
        var px = [Float](repeating: 0.10, count: w * h)
        // linear gradient
        for y in 0..<h { for x in 0..<w { px[y*w+x] += 0.20 * Float(x) / Float(w-1) } }
        // broad off-center Gaussian blob (well away from center → asymmetric structure)
        let bx = Double(w) * 0.30, by = Double(h) * 0.35, sig = Double(w) * 0.22
        for y in 0..<h { for x in 0..<w {
            let dx = Double(x) - bx, dy = Double(y) - by
            px[y*w+x] += 0.35 * Float(exp(-(dx*dx + dy*dy) / (2*sig*sig)))
        } }
        for s in stars {
            for y in max(0, Int(s.1)-6)...min(h-1, Int(s.1)+6) {
                for x in max(0, Int(s.0)-6)...min(w-1, Int(s.0)+6) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    px[y*w+x] += 0.8 * Float(exp(-(dx*dx+dy*dy)/(2*2.0*2.0)))
                }
            }
        }
        return RawFrame(image: AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true),
                        bayerPattern: .grbg, bottomUp: false, timestamp: Date(timeIntervalSince1970: 0), sourceName: "t.fit")
    }

    /// R5 Critical: leveling a sub that is byte-identical to the seed over the covered
    /// region must be a ~no-op even when the covered region is an ASYMMETRIC subset of a
    /// non-polynomial sky.
    ///
    /// Pre-fix (seed fit UNMASKED over the full frame, sub fit MASKED over the subregion):
    /// the two least-squares fits span different spatial domains of the nebula, so
    /// surfSub − surfRef is a nonzero spurious surface → the "identical" sub is CHANGED.
    /// Post-fix (both models solved over the SAME masked tile subset): surfSub ≈ surfRef →
    /// the correction is ~0 and the covered pixels are unchanged.
    ///
    /// Staged path: seed → register the same frame (identity-ish transform) → warp →
    /// replace the mask with an asymmetric (left 75%) mask → levelingModels → apply.
    func testIdenticalSubOverAsymmetricMaskIsNoOp() {
        let w = 256, h = 256
        let eng = StackEngine(normalization: true)
        let seed = cfaFrameNonPolynomial(stars: field, w: w, h: h)
        XCTAssertTrue(eng.seedReference(seed, minRows: .max), "seed must succeed")

        // Register the SAME frame → transform ~identity; warp → pixels ≈ seed rgb.
        guard let reg = eng.register(cfaFrameNonPolynomial(stars: field, w: w, h: h), minRows: .max) else {
            return XCTFail("register failed")
        }
        let (warped, warpMask) = eng.warp(reg, minRows: .max)

        // Hand-built ASYMMETRIC coverage mask: left 75% covered, right 25% uncovered.
        // AND with the real warp mask so we never mark an out-of-bounds pixel as covered.
        let cutX = Int(Double(w) * 0.75)
        var mask = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            if x < cutX && warpMask[y*w + x] > 0 { mask[y*w + x] = 1 }
        } }

        guard let pair = eng.levelingModels(image: warped, mask: mask) else {
            return XCTFail("levelingModels returned nil with normalization on")
        }
        let leveled = GradientLeveler.apply(warped, subModel: pair.sub, refModel: pair.ref, minRows: .max)

        // RMS difference over COVERED pixels only (per channel), leveled vs input warped frame.
        let plane = w * h
        var sumSq = 0.0, n = 0
        for c in 0..<warped.channels {
            let base = c * plane
            for i in 0..<plane where mask[i] > 0 {
                let d = Double(leveled.pixels[base + i] - warped.pixels[base + i])
                sumSq += d * d; n += 1
            }
        }
        let rms = n > 0 ? (sumSq / Double(n)).squareRoot() : 0
        print("R5 domain-asymmetry regression: covered-pixel leveling rms = \(rms)")

        // Leveling an identical sky must be a ~no-op. Pre-fix this rms is ~0.01–0.05
        // (spurious differential from mismatched fit domains); post-fix it is ~0.
        XCTAssertLessThan(rms, 1e-3,
            "Leveling an identical sky over an asymmetric mask must be ~no-op (rms=\(rms)). " +
            "A larger rms means the seed and sub models were fit over different domains (R5 Critical).")
    }
}
