import XCTest
@testable import LiveAstroCore

// ---------------------------------------------------------------------------
// ParityTests: verify that StackEngine's star-detection and registration
// pipeline produces a transform that agrees with the reference computed by
// astroalign on two real NGC 6888 subs (see Scripts/make_parity_fixtures.py).
//
// Orientation note
// ----------------
// The fixture files have no ROWORDER header, so FITSReader.read() defaults
// to bottomUp = true and flips the pixel rows to top-down on load.
// FolderFrameSource.loadRawFrame() stores these already-flipped pixels in
// RawFrame.image, keeping RawFrame.bottomUp = true.  StackEngine's luminance
// loop uses  srcRow = hh − 1 − j  (when bottomUp), which re-flips them back
// to stored (bottom-up) order.  Net effect: double flip = identity.  The
// luminance seen by StarDetector is therefore in STORED (bottom-up) order,
// matching the orientation in parity_expected.json.
// ---------------------------------------------------------------------------

final class ParityTests: XCTestCase {

    // MARK: – JSON model

    private struct Expected: Decodable {
        let rotation_deg: Double
        let scale: Double
        let tx: Double
        let ty: Double
        let n_source_stars_min: Int
    }

    // MARK: – Helpers

    /// Build the same half-res superpixel luminance StackEngine builds.
    /// When bottomUp is true the row-read order is reversed, so the net
    /// effect for files loaded via loadRawFrame (which already flipped) is
    /// stored (bottom-up) order — identical to the Python fixture script.
    private func buildLuminance(frame: RawFrame) -> ([Float], Int, Int) {
        let raw = frame.image
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
        return (lum, hw, hh)
    }

    /// Load the parity_expected.json from the test bundle.
    private func loadExpected() throws -> Expected {
        guard let fixturesDir = Bundle.module.resourceURL?.appendingPathComponent("Fixtures") else {
            throw XCTSkip("Bundle resource URL unavailable — build with SPM (swift test)")
        }
        let url = fixturesDir.appendingPathComponent("parity_expected.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Expected.self, from: data)
    }

    /// Load a fixture FITS file via FolderFrameSource (the production path).
    private func loadFixture(name: String) throws -> RawFrame {
        guard let fixturesDir = Bundle.module.resourceURL?.appendingPathComponent("Fixtures") else {
            throw XCTSkip("Bundle resource URL unavailable — build with SPM (swift test)")
        }
        let url = fixturesDir.appendingPathComponent(name)
        return try FolderFrameSource.loadRawFrame(url: url)
    }

    // MARK: – Tests

    func testParityStarCount() throws {
        let expected = try loadExpected()
        let frameA = try loadFixture(name: "parity_a.fit")
        let frameB = try loadFixture(name: "parity_b.fit")

        let (lumA, hwA, hhA) = buildLuminance(frame: frameA)
        let (lumB, hwB, hhB) = buildLuminance(frame: frameB)

        let starsA = StarDetector.detect(luminance: lumA, width: hwA, height: hhA)
        let starsB = StarDetector.detect(luminance: lumB, width: hwB, height: hhB)

        XCTAssertGreaterThanOrEqual(
            starsA.count, expected.n_source_stars_min,
            "parity_a.fit: StarDetector found \(starsA.count), need ≥ \(expected.n_source_stars_min)")
        XCTAssertGreaterThanOrEqual(
            starsB.count, expected.n_source_stars_min,
            "parity_b.fit: StarDetector found \(starsB.count), need ≥ \(expected.n_source_stars_min)")
    }

    func testParityTransform() throws {
        let expected = try loadExpected()
        let frameA = try loadFixture(name: "parity_a.fit")
        let frameB = try loadFixture(name: "parity_b.fit")

        let (lumA, hwA, hhA) = buildLuminance(frame: frameA)
        let (lumB, hwB, hhB) = buildLuminance(frame: frameB)

        let starsA = StarDetector.detect(luminance: lumA, width: hwA, height: hhA)
        let starsB = StarDetector.detect(luminance: lumB, width: hwB, height: hhB)

        XCTAssertGreaterThanOrEqual(starsA.count, expected.n_source_stars_min,
            "Too few stars in A (\(starsA.count)) for a meaningful transform test")
        XCTAssertGreaterThanOrEqual(starsB.count, expected.n_source_stars_min,
            "Too few stars in B (\(starsB.count)) for a meaningful transform test")

        let pairs = TriangleMatcher.correspondences(source: starsA, target: starsB)
        guard let tf = TransformSolver.solve(source: starsA, target: starsB, pairs: pairs) else {
            XCTFail("TransformSolver could not find a transform A→B")
            return
        }

        let rotDeg = tf.rotation * 180.0 / .pi
        XCTAssertEqual(rotDeg, expected.rotation_deg, accuracy: 0.05,
            "rotation mismatch: swift=\(rotDeg)° expected=\(expected.rotation_deg)°")
        XCTAssertEqual(tf.scale, expected.scale, accuracy: 1e-3,
            "scale mismatch: swift=\(tf.scale) expected=\(expected.scale)")
        XCTAssertEqual(tf.tx, expected.tx, accuracy: 0.5,
            "tx mismatch: swift=\(tf.tx) expected=\(expected.tx)")
        XCTAssertEqual(tf.ty, expected.ty, accuracy: 0.5,
            "ty mismatch: swift=\(tf.ty) expected=\(expected.ty)")
    }
}
