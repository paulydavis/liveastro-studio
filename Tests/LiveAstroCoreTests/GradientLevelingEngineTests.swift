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
    let field: [(Double, Double)] = [
        (30,30),(90,60),(150,90),(210,120),(60,150),(120,180),(180,210),(40,200),(200,40),(100,100),
        (160,50),(50,90),(140,140),(80,220),(220,80),(110,30),(30,110),(190,190),(70,70),(150,200)
    ]

    func testRegisterProducesBackgroundModelWhenOn() {
        let eng = StackEngine(normalization: true)
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
        let reg = eng.register(cfaFrame(stars: field, slope: 0.10), minRows: .max)
        XCTAssertNotNil(reg?.backgroundModel)
        XCTAssertNotNil(reg?.backgroundModel?.coeffPerChannel[0] ?? nil)
    }

    func testRegisterModelNilWhenOff() {
        let eng = StackEngine(normalization: false)
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
        XCTAssertNil(eng.register(cfaFrame(stars: field, slope: 0.10), minRows: .max)?.backgroundModel)
    }

    func testOffPathByteIdentical() {
        // normalization:false must equal a stack that never applies the leveler.
        func run(_ on: Bool) -> [Float] {
            let eng = StackEngine(normalization: on)
            _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
            for _ in 0..<4 {
                if let reg = eng.register(cfaFrame(stars: field, slope: 0.0), minRows: .max) {
                    let (img, mask) = eng.warp(reg, minRows: .max)
                    eng.commit(image: img, mask: mask, frameWeight: reg.weight,
                               backgroundModel: reg.backgroundModel, minRows: .max)
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
                    eng.commit(image: img, mask: mask, frameWeight: reg.weight,
                               backgroundModel: reg.backgroundModel, minRows: .max)
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
            eng.commit(image: img, mask: mask, frameWeight: reg.weight, backgroundModel: reg.backgroundModel, minRows: .max)
            // the committed (leveled) frame ≈ the warped frame (flat vs flat → ~no change) at a mid sky pixel
            XCTAssertEqual(eng.currentStack()!.pixels[100*eng.currentStack()!.width + 5], before[100*img.width + 5], accuracy: 0.03)
        } else { XCTFail("register failed") }
    }
}
