import XCTest
@testable import LiveAstroCore

final class StarDetectorStatsTests: XCTestCase {
    // Flat sky + a few Gaussian stars + noise.
    func luminance(w: Int, h: Int, noise: Float, seed: UInt64) -> [Float] {
        var g = SystemRandomNumberGeneratorStub(seed: seed)
        var px = [Float](repeating: 0.05, count: w*h)
        let stars: [(Int,Int)] = [(20,20),(60,30),(40,55),(75,70),(15,65),(50,40),(30,15),(70,20),(25,45),(55,60)]
        for (sx,sy) in stars {
            for y in max(0,sy-3)...min(h-1,sy+3) { for x in max(0,sx-3)...min(w-1,sx+3) {
                let dx = Float(x-sx), dy = Float(y-sy)
                px[y*w+x] += 0.7*expf(-(dx*dx+dy*dy)/(2*1.2*1.2))
            } }
        }
        for i in 0..<px.count { px[i] += noise * g.nextGaussian() }
        return px.map { min(max($0,0),1) }
    }

    func testDetectWithStatsMatchesDetectAndReturnsPositiveSigma() {
        let w = 90, h = 90
        let lum = luminance(w: w, h: h, noise: 0.01, seed: 1)
        let r = StarDetector.detectWithStats(luminance: lum, width: w, height: h)
        XCTAssertEqual(r.stars, StarDetector.detect(luminance: lum, width: w, height: h))
        XCTAssertGreaterThan(r.backgroundSigma, 0)
    }

    func testNoisierFrameHasLargerSigma() {
        let w = 90, h = 90
        let quiet = StarDetector.detectWithStats(luminance: luminance(w: w, h: h, noise: 0.01, seed: 2), width: w, height: h)
        let noisy = StarDetector.detectWithStats(luminance: luminance(w: w, h: h, noise: 0.05, seed: 2), width: w, height: h)
        XCTAssertGreaterThan(noisy.backgroundSigma, quiet.backgroundSigma)
    }
}

/// Deterministic Gaussian noise source for reproducible tests.
struct SystemRandomNumberGeneratorStub {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func nextGaussian() -> Float {
        let u1 = Float(next() >> 11) * (1.0/9007199254740992.0)
        let u2 = Float(next() >> 11) * (1.0/9007199254740992.0)
        return sqrtf(-2*logf(max(u1,1e-7))) * cosf(2 * .pi * u2)
    }
}
