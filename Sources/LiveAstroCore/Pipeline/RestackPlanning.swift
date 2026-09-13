import Foundation

/// Pure, testable core of the post-session "re-stack the master minus flagged subs" glue
/// that otherwise lived on `AppModel` (the `LiveAstroStudio` executable target, which the
/// test target cannot `@testable import`). The trust-critical steps — which subs survive
/// and how the rebuilt master is encoded to FITS — are relocated here so they can be
/// pinned by unit tests; `AppModel` keeps only the main-actor driving + FileManager I/O.
/// One survivor the re-stack must reload: its on-disk URL plus the file identity recorded at
/// capture (nil for legacy subs predating identity capture). The re-stack loads via
/// `FolderFrameSource.loadRawFrame(url:expectedDigest:)` — CONTENT-DIGEST validation that
/// IGNORES inode/mtime, so a Google-Drive-mirror / SMB re-sync that recreates a byte-identical
/// file is kept, while a genuine content change (different SHA-256) is skipped.
/// `expectedIdentity?.digest == nil` (legacy, predates content-digest capture) loads unverified.
public struct RestackSub: Equatable {
    public let url: URL
    public let expectedIdentity: FileIdentity?
    public let exposure: FrameExposure?
    public init(url: URL, expectedIdentity: FileIdentity?, exposure: FrameExposure? = nil) {
        self.url = url
        self.expectedIdentity = expectedIdentity
        self.exposure = exposure
    }
}

public enum RestackPlanning {
    /// Update current-master facts without rewriting historical snapshots or intake totals.
    public static func updatingMaster(in manifest: SessionManifest, report: RestackReport,
                                      fallbackExposureSeconds: Double) -> SessionManifest {
        var result = manifest
        let exposure = report.exposure ?? .estimated(count: report.stackedCount, seconds: fallbackExposureSeconds)
        result.exposure = exposure
        result.stackFrameCount = report.stackedCount
        result.masterOutcome = .written
        result.subExposureSeconds = exposure.uniformSeconds ?? 0
        return result
    }
    /// The survivor set the re-stack processes, resolved from the session's RECORDED subs
    /// (not a folder listing): recorded order (index-ascending), minus operator-flagged
    /// (`rejectedByUser`) subs. Intake-`.rejected` subs are INCLUDED — they were part of
    /// the sequence the live pipeline processed, so replaying them reproduces the same
    /// integration. Each survivor pairs `dir/sourceFile` with the record's captured
    /// `identity` (nil for legacy records) so the re-stack can verify content on reload.
    /// `RestackCoordinator.skippedMissing` absorbs any listed sub since deleted from disk.
    public static func survivorSubs(subFrames: [SubFrameRecord], in dir: URL) -> [RestackSub] {
        subFrames.sorted { $0.index < $1.index }        // recorded order (UI mirror may be out-of-order)
                 .filter { !$0.rejectedByUser }
                 .map { RestackSub(url: dir.appendingPathComponent($0.sourceFile),
                                   expectedIdentity: $0.identity, exposure: $0.exposure) }
    }

    /// Encodes a re-stacked master to a full-metadata float32 FITS, matching the live
    /// pipeline's master write (`SessionPipeline.writeMasterSnapshot`/`end()`): crop to the
    /// covered region (`CoverageCrop.cropToCoverage`), optionally background-neutralize
    /// (`AutoStretch.neutralizeBackgroundAdditive`) when the session ran with the flag set,
    /// then `FITSWriter.float32(..., metadata:, stackCount:, totalExposureSeconds:)`. This
    /// is the pure encode step only — the tmp-file/atomic-replace I/O stays in `AppModel`
    /// (it needs FileManager). Relocating it here does NOT change a pixel or a header.
    public static func encodeMaster(_ report: RestackReport, neutralize: Bool,
                                    metadata: SourceMetadata?, subExposureSeconds: Double) -> Data {
        let balanced = presentationMaster(report, neutralize: neutralize)
        // Parity with the live master: the subs' own EXPTIME wins, the profile is the fallback.
        let exposure = SourceMetadata.resolvedExposureSeconds(metadata: metadata, fallback: subExposureSeconds)
        let totalExp = report.exposure?.totalSeconds ?? Double(report.stackedCount) * exposure
        return FITSWriter.float32(width: balanced.width, height: balanced.height,
            channels: balanced.channels, pixels: balanced.pixels,
            metadata: report.exposure?.masterMetadata(metadata) ?? metadata?.metadataForMaster,
            stackCount: report.stackedCount, totalExposureSeconds: totalExp,
            estimatedExposureFrames: report.exposure?.estimatedFrameCount ?? report.stackedCount)
    }

    /// The presentation master: report.master cropped to coverage and (optionally) background-neutralized —
    /// the exact image that encodeMaster writes to master.fit. Used for both the FITS write and the UI preview
    /// so they never disagree.
    public static func presentationMaster(_ report: RestackReport, neutralize: Bool) -> AstroImage {
        let cropped = CoverageCrop.cropToCoverage(report.master, coverage: report.coverage)   // crop BEFORE balance
        return neutralize ? AutoStretch.neutralizeBackgroundAdditive(cropped) : cropped
    }
}
