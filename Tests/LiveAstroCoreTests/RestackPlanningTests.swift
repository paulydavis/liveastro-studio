import XCTest
@testable import LiveAstroCore

/// Pins the four trust-critical properties of the post-session re-stack glue that was
/// relocated from `AppModel` (untestable — executable target) into `RestackPlanning`.
final class RestackPlanningTests: XCTestCase {

    // MARK: helpers

    private func record(index: Int, file: String, outcome: SubFrameOutcome,
                        rejectedByUser: Bool, identity: FileIdentity? = nil) -> SubFrameRecord {
        SubFrameRecord(index: index, timestamp: Date(timeIntervalSince1970: 0),
                       sourceFile: file, starCount: 100, backgroundSigma: 1, weight: 1,
                       outcome: outcome, rejectionReason: nil, rejectedByUser: rejectedByUser,
                       identity: identity)
    }

    private func image(width: Int, height: Int, channels: Int,
                       _ f: (Int, Int, Int) -> Float) -> AstroImage {
        var px = [Float](repeating: 0, count: width * height * channels)
        let plane = width * height
        for c in 0..<channels {
            for y in 0..<height { for x in 0..<width { px[c * plane + y * width + x] = f(x, y, c) } }
        }
        return AstroImage(width: width, height: height, channels: channels,
                          pixels: px, sourceIsLinear: true)
    }

    // MARK: 1 — survivor selection

    func testSurvivorSubsOrdersAscendingExcludesUserFlaggedKeepsIntakeRejected() {
        let dir = URL(fileURLWithPath: "/tmp/session")
        // Shuffled input: mixed indices, some rejectedByUser, some intake-.rejected.
        let subs = [
            record(index: 3, file: "c.fit", outcome: .stacked,   rejectedByUser: false),
            record(index: 0, file: "a.fit", outcome: .reference, rejectedByUser: false),
            record(index: 4, file: "d.fit", outcome: .stacked,   rejectedByUser: true),   // user-flagged → dropped
            record(index: 2, file: "b.fit", outcome: .rejected,  rejectedByUser: false),  // intake-rejected → KEPT
            record(index: 1, file: "e.fit", outcome: .stacked,   rejectedByUser: true),   // user-flagged → dropped
        ]
        let survivors = RestackPlanning.survivorSubs(subFrames: subs, in: dir)

        // Ascending by index, user-flagged excluded, intake-.rejected included.
        XCTAssertEqual(survivors.map { $0.url.lastPathComponent }, ["a.fit", "b.fit", "c.fit"])
        // Each URL is dir/sourceFile.
        XCTAssertEqual(survivors.map(\.url), ["a.fit", "b.fit", "c.fit"].map { dir.appendingPathComponent($0) })
    }

    /// survivorSubs must carry each record's captured `identity` onto the matching RestackSub,
    /// so the re-stack can content-verify each sub on reload (and load legacy nil-identity
    /// records unverified).
    func testSurvivorSubsCarryRecordedIdentity() {
        let dir = URL(fileURLWithPath: "/tmp/session")
        let idA = FileIdentity(dev: 1, ino: 10, size: 1000, mtimeSec: 111, mtimeNsec: 222)
        let idC = FileIdentity(dev: 1, ino: 12, size: 3000, mtimeSec: 333, mtimeNsec: 444, digest: "deadbeef")
        let subs = [
            record(index: 0, file: "a.fit", outcome: .reference, rejectedByUser: false, identity: idA),
            record(index: 1, file: "b.fit", outcome: .stacked,   rejectedByUser: false, identity: nil),  // legacy
            record(index: 2, file: "c.fit", outcome: .stacked,   rejectedByUser: false, identity: idC),
        ]
        let survivors = RestackPlanning.survivorSubs(subFrames: subs, in: dir)
        XCTAssertEqual(survivors.map(\.expectedIdentity), [idA, nil, idC])
    }

    // MARK: 2 — metadata headers

    func testEncodeMasterStampsStackCountAndTotalExposure() throws {
        let master = image(width: 4, height: 4, channels: 1) { _, _, _ in 0.5 }
        let report = RestackReport(master: master, stackedCount: 5, skippedMissing: 0,
                                   skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        let subExp = 30.0   // 5 × 30 = 150, a clean whole-number TOTALEXP

        let data = RestackPlanning.encodeMaster(report, neutralize: false,
                                                metadata: nil, subExposureSeconds: subExp)
        let header = try FITSReader.readHeader(data)
        XCTAssertEqual(header.keywords["STACKCNT"], "5")
        XCTAssertEqual(header.keywords["TOTALEXP"], "150")
    }

    // MARK: 3 — crop-to-coverage applied

    func testEncodeMasterCropsToCoverage() throws {
        // 10×10 master; coverage covers only the inner 8×8 (area 64 ≥ 60% of 100 → crops).
        let w = 10, h = 10
        let master = image(width: w, height: h, channels: 1) { x, y, _ in Float(y * w + x) }
        var coverage = [Float](repeating: 0, count: w * h)
        for y in 1...8 { for x in 1...8 { coverage[y * w + x] = 10 } }
        let report = RestackReport(master: master, stackedCount: 1, skippedMissing: 0,
                                   skippedMismatch: 0, unverifiedLegacy: false, coverage: coverage)

        let data = RestackPlanning.encodeMaster(report, neutralize: false,
                                                metadata: nil, subExposureSeconds: 1)
        let decoded = try FITSReader.read(data)
        // Decoded dims are the cropped inner rect (8×8), not the full 10×10 frame.
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
    }

    // MARK: 4 — neutralize honored

    func testEncodeMasterNeutralizeChangesOutput() {
        // 3-channel master with a per-channel colored background gradient (R ramps, G/B flat)
        // → neutralizeBackgroundAdditive shifts pixels, so the encoded bytes must differ.
        let master = image(width: 64, height: 64, channels: 3) { x, _, c in
            c == 0 ? 0.1 + Float(x) / 640.0 : 0.1
        }
        let report = RestackReport(master: master, stackedCount: 1, skippedMissing: 0,
                                   skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)

        let plain      = RestackPlanning.encodeMaster(report, neutralize: false, metadata: nil, subExposureSeconds: 1)
        let neutralized = RestackPlanning.encodeMaster(report, neutralize: true,  metadata: nil, subExposureSeconds: 1)

        // The neutralize:true path ran neutralizeBackgroundAdditive; its pixels differ.
        XCTAssertNotEqual(plain, neutralized)
    }
}
