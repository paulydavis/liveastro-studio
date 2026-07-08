import XCTest
@testable import LiveAstroCore

// ---------------------------------------------------------------------------
// ParityTests: verify that StackEngine's star-detection and registration
// pipeline produces a transform that agrees with the reference computed by
// astroalign on two real NGC 6888 subs (see Scripts/make_parity_fixtures.py).
//
// Orientation note
// ----------------
// The fixture files have no ROWORDER header (defaults BOTTOM-UP), so
// loadRawFrame returns STORED-order pixels with bottomUp = true, and the
// luminance builder below (mirroring StackEngine) flips rows to DISPLAY
// orientation — matching parity_expected.json, which the fixture script
// computes in the same display frame.
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

    /// Exactly the production half-res superpixel luminance (via @testable):
    /// parity against astroalign is only meaningful over the same binning and
    /// display-orientation flip StackEngine registers on.
    private func buildLuminance(frame: RawFrame) -> ([Float], Int, Int) {
        StackEngine.halfResLuminance(frame: frame)
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
