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
        let engine = StackEngine(scaleNormalization: true)
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
            let engine = StackEngine(scaleNormalization: scaleOn)
            XCTAssertTrue(engine.seedReference(seedFrame, minRows: .max))
            for i in 0..<9 {
                let sub = cfaFrame(stars: shifted, amp: 0.8 * 0.7, name: "sub\(i).fit")
                if let reg = engine.register(sub, minRows: .max) {
                    let w = engine.warp(reg, minRows: .max)
                    engine.commit(image: w.image, mask: w.mask, scale: reg.scale, minRows: .max)
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
        // A dimmed sub's weight with scaling ON (σ·s) is LOWER than with scaling OFF (σ·1),
        // because the scale factor s > 1 inflates the effective noise term.
        let seedFrame = cfaFrame(stars: field, amp: 0.8)
        let shifted = field.map { (x: $0.x + 3.0, y: $0.y - 2.0) }
        let sub = cfaFrame(stars: shifted, amp: 0.8 * 0.7)

        let engineOff = StackEngine(frameWeighting: true, scaleNormalization: false)
        XCTAssertTrue(engineOff.seedReference(seedFrame, minRows: .max))
        let regOff = engineOff.register(sub, minRows: .max)
        XCTAssertNotNil(regOff)

        let engineOn = StackEngine(frameWeighting: true, scaleNormalization: true)
        XCTAssertTrue(engineOn.seedReference(seedFrame, minRows: .max))
        let regOn = engineOn.register(sub, minRows: .max)
        XCTAssertNotNil(regOn)

        // scale > 1 → σ·s > σ → noise is judged higher → weight is lower
        XCTAssertGreaterThan(regOn!.scale, 1.0)
        XCTAssertLessThan(regOn!.weight, regOff!.weight,
            "Weight with scaling ON (\(regOn!.weight)) should be < OFF (\(regOff!.weight)) for a dimmed sub")
    }

    // MARK: - scaleBaseline reset on reseed

    func testScaleBaselineResetOnReseed() {
        // Seed a BRIGHT field → reseed → seed a NORMAL field → commit an identical normal sub.
        // With correct reset, the master pixels after commit should be near-unchanged from the
        // normal seed (the bright scaleBaseline must NOT bleed into the second session).
        let brightField = cfaFrame(stars: field, amp: 0.9, bg: 0.2)
        let normalSeed  = cfaFrame(stars: field, amp: 0.8, bg: 0.05)
        let shifted     = field.map { (x: $0.x + 2.0, y: $0.y - 1.5) }
        let normalSub   = cfaFrame(stars: shifted, amp: 0.8, bg: 0.05)

        let engine = StackEngine(scaleNormalization: true)
        XCTAssertTrue(engine.seedReference(brightField, minRows: .max))
        engine.reseed()
        XCTAssertTrue(engine.seedReference(normalSeed, minRows: .max))

        let reg = engine.register(normalSub, minRows: .max)
        XCTAssertNotNil(reg)
        let w = engine.warp(reg!, minRows: .max)
        engine.commit(image: w.image, mask: w.mask, scale: reg!.scale, minRows: .max)

        // The normal sub's scale against the normal seed should be close to 1 (same brightness).
        XCTAssertEqual(reg!.scale, 1.0, accuracy: 0.3)

        // The stack should be close to the seed brightness (sky around the edge should be
        // roughly the normal background level, not the bright one).
        let stack = engine.currentStack()!
        // Sample a sky pixel far from any star — use top-left corner area
        let skyVal = stack.pixels[0]   // top-left, far from any star (which starts at 60.2,80.5)
        XCTAssertLessThan(skyVal, 0.25, "Sky should be near normal background after reseed, not bright one")
    }
}
