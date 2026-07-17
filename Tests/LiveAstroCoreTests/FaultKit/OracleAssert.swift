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
///   (5) unpersisted work is never reported successful: an ended native manifest
///       (`master_expected == true`) must make one typed claim. `.written` requires a durable,
///       decodable `master.fit` whose FITS `STACKCNT` matches `stack_frame_count`; `.awaiting_seed`
///       and `.no_frames` require `stack_frame_count == 0` plus the matching honest log. Watcher
///       sessions honestly expect none (the stack lives with the external stacker). LEGACY ended
///       native manifests with `master_expected == true` but no typed outcome fall back to the
///       review-11 rule: snapshots imply a required master. Ancient manifests with no
///       `master_expected` remain era-exempt because mode is unknowable. A running session
///       (`end_time == nil`) is exempt.
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

    // Clause 5: unpersisted work never reported successful — typed post-schema outcomes are
    // checked against the actual durable artifact/log, while documented legacy eras keep their
    // compatibility behavior.
    if manifest.endTime != nil, manifest.masterExpected == true {
        switch manifest.masterOutcome {
        case .written?:
            guard let stackFrameCount = manifest.stackFrameCount else {
                XCTFail("oracle clause 5: written master outcome lacks stack_frame_count",
                        file: file, line: line)
                break
            }
            assertDecodableMaster(
                sessionRoot: sessionRoot,
                expectedStackCount: stackFrameCount,
                file: file,
                line: line)
        case .awaitingSeed?:
            XCTAssertEqual(manifest.stackFrameCount, 0,
                           "oracle clause 5: awaiting_seed outcome must record stack_frame_count == 0",
                           file: file, line: line)
            assertLogContains(
                "reference cleared by reseed (manual or automatic) and never re-seeded",
                log: log,
                message: "oracle clause 5: awaiting_seed outcome lacks honest reseed/no-master log",
                file: file,
                line: line)
        case .noFrames?:
            XCTAssertEqual(manifest.stackFrameCount, 0,
                           "oracle clause 5: no_frames outcome must record stack_frame_count == 0",
                           file: file, line: line)
            assertLogContainsExactly(
                "no frames accepted — no master written",
                log: log,
                message: "oracle clause 5: no_frames outcome lacks honest no-master log",
                file: file,
                line: line)
        case nil:
            if !manifest.snapshots.isEmpty {
                let master = sessionRoot.appendingPathComponent("master.fit")
                XCTAssertTrue(fm.fileExists(atPath: master.path),
                              "oracle clause 5: legacy ended native manifest has snapshots but no persisted master.fit",
                              file: file, line: line)
            }
        }
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

private func assertDecodableMaster(sessionRoot: URL,
                                   expectedStackCount: Int,
                                   file: StaticString,
                                   line: UInt) {
    let master = sessionRoot.appendingPathComponent("master.fit")
    let values = try? master.resourceValues(forKeys: [.isRegularFileKey])
    XCTAssertEqual(values?.isRegularFile, true,
                   "oracle clause 5: written outcome master.fit is not a regular file",
                   file: file, line: line)
    guard let bytes = try? Data(contentsOf: master), !bytes.isEmpty else {
        XCTFail("oracle clause 5: written outcome has no readable master.fit",
                file: file, line: line)
        return
    }
    guard let header = try? FITSReader.readHeader(bytes) else {
        XCTFail("oracle clause 5: master.fit header is not decodable FITS",
                file: file, line: line)
        return
    }
    guard (try? FITSReader.read(bytes)) != nil else {
        XCTFail("oracle clause 5: master.fit pixels are not decodable FITS",
                file: file, line: line)
        return
    }
    guard let raw = header.keywords["STACKCNT"], let stackCount = Int(raw) else {
        XCTFail("oracle clause 5: written master lacks integer STACKCNT",
                file: file, line: line)
        return
    }
    XCTAssertEqual(stackCount, expectedStackCount,
                   "oracle clause 5: master STACKCNT \(stackCount) != manifest stack_frame_count \(expectedStackCount)",
                   file: file, line: line)
}

private func assertLogContains(_ needle: String,
                               log: [String],
                               message: String,
                               file: StaticString,
                               line: UInt) {
    let matched = log.contains { $0.contains(needle) }
    XCTAssertTrue(matched, "\(message)\nlog:\n\(log.joined(separator: "\n"))", file: file, line: line)
}

private func assertLogContainsExactly(_ expected: String,
                                      log: [String],
                                      message: String,
                                      file: StaticString,
                                      line: UInt) {
    let matched = log.contains { $0 == expected }
    XCTAssertTrue(matched, "\(message)\nlog:\n\(log.joined(separator: "\n"))", file: file, line: line)
}
