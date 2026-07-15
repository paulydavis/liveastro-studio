import Foundation
import XCTest
import ImageIO
@testable import LiveAstroCore

/// Scenario-specific expectations, passed EXPLICITLY so the oracle is never silently weakened.
struct OracleExpectations {
    /// Regex the captured log must match (nil = no loss/degradation expected → log not required to match).
    var lossLogPattern: String?
    /// Does clause 3 (later valid frames still accepted) apply to this scenario? Asserted by the
    /// TEST (which keeps feeding frames); the oracle only documents applicability.
    var laterFramesApplicable: Bool
    /// Clause 2: exact manifest snapshot count when the test knows it (nil = don't pin the count).
    var expectedAcceptedCount: Int?
}

/// The session oracle: verifies the six-clause invariant against an on-disk session root and a
/// captured log after an injected fault. Every fault test's FINAL statement.
///
/// Clause map (design §"The Invariant and the Oracle"):
///   (1) manifest.json at `sessionRoot` parses as the production `SessionManifest`.
///   (2) snapshots listed in the manifest exist on disk; count matches `expectedAcceptedCount` if set.
///   (3) later valid frames continue to be accepted — asserted by the TEST; documented via
///       `laterFramesApplicable` (a value of true without the test feeding frames is a test smell).
///   (4) finalization inputs are readable AND decodable: every listed snapshot PNG opens as a real
///       image (CGImageSource decodes at least one frame) — non-empty bytes are not enough; a listed
///       snapshot that is garbage/text fails here (recoverable output path).
///   (5) unpersisted work is never reported successful: a manifest with `end_time` set (claims the
///       session ended) MUST have a durable `master.fit` — an ended claim without the persisted end
///       artifact is dishonest. (SessionManifest has no separate status field; `end_time` + master.fit
///       is the durable end. A running session — end_time nil — is exempt.)
///   (6) the log matches `lossLogPattern` when set.
func assertSessionOracle(sessionRoot: URL, log: [String],
                         _ e: OracleExpectations,
                         file: StaticString = #filePath, line: UInt = #line) {
    let fm = FileManager.default
    let manifestURL = sessionRoot.appendingPathComponent("manifest.json")

    // Clause 1: the last durable manifest remains readable and parses.
    guard let data = try? Data(contentsOf: manifestURL) else {
        XCTFail("oracle clause 1: manifest.json unreadable at \(manifestURL.path)", file: file, line: line)
        return
    }
    guard let manifest = try? ManifestCoding.decoder().decode(SessionManifest.self, from: data) else {
        XCTFail("oracle clause 1: manifest.json does not parse as SessionManifest", file: file, line: line)
        return
    }

    // Clause 2: previously accepted snapshots remain honest — each listed file exists; count truthful.
    for snap in manifest.snapshots {
        let p = sessionRoot.appendingPathComponent(snap.snapshotFile)
        XCTAssertTrue(fm.fileExists(atPath: p.path),
                      "oracle clause 2: listed snapshot missing on disk: \(snap.snapshotFile)",
                      file: file, line: line)
    }
    if let expected = e.expectedAcceptedCount {
        XCTAssertEqual(manifest.snapshots.count, expected,
                       "oracle clause 2: manifest snapshot count \(manifest.snapshots.count) != expected \(expected)",
                       file: file, line: line)
    }

    // Clause 4: finalization/replay inputs readable AND decodable — every listed snapshot must open
    // as a real image, not merely be non-empty bytes. A listed snapshot replaced by text/garbage
    // (nonzero length, undecodable) is a silently-corrupt output and must fail here.
    for snap in manifest.snapshots {
        let p = sessionRoot.appendingPathComponent(snap.snapshotFile)
        guard let bytes = try? Data(contentsOf: p), !bytes.isEmpty else {
            XCTFail("oracle clause 4: snapshot not readable for finalization: \(snap.snapshotFile)",
                    file: file, line: line)
            continue
        }
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else {
            XCTFail("oracle clause 4: snapshot present but not decodable as an image: \(snap.snapshotFile)",
                    file: file, line: line)
            continue
        }
    }

    // Clause 5: unpersisted work never reported successful — an ended claim needs the durable end.
    if manifest.endTime != nil {
        let master = sessionRoot.appendingPathComponent("master.fit")
        XCTAssertTrue(fm.fileExists(atPath: master.path),
                      "oracle clause 5: manifest has end_time (claims ended) but no persisted master.fit",
                      file: file, line: line)
    }

    // Clause 6: the log identifies the loss/degradation when one is expected.
    if let pattern = e.lossLogPattern {
        let joined = log.joined(separator: "\n")
        let matched = joined.range(of: pattern, options: .regularExpression) != nil
        XCTAssertTrue(matched,
                      "oracle clause 6: log does not match loss pattern /\(pattern)/\nlog:\n\(joined)",
                      file: file, line: line)
    }
}
