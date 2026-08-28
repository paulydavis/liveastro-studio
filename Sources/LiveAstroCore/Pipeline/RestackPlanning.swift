import Foundation

/// Pure, testable core of the post-session "re-stack the master minus flagged subs" glue
/// that otherwise lived on `AppModel` (the `LiveAstroStudio` executable target, which the
/// test target cannot `@testable import`). The trust-critical steps — which subs survive
/// and how the rebuilt master is encoded to FITS — are relocated here so they can be
/// pinned by unit tests; `AppModel` keeps only the main-actor driving + FileManager I/O.
public enum RestackPlanning {
    /// The survivor set the re-stack processes, resolved from the session's RECORDED subs
    /// (not a folder listing): recorded order (index-ascending), minus operator-flagged
    /// (`rejectedByUser`) subs. Intake-`.rejected` subs are INCLUDED — they were part of
    /// the sequence the live pipeline processed, so replaying them reproduces the same
    /// integration. Each URL is `dir/sourceFile`. `RestackCoordinator.skippedMissing`
    /// absorbs any listed sub since deleted from disk.
    public static func survivorURLs(subFrames: [SubFrameRecord], in dir: URL) -> [URL] {
        subFrames.sorted { $0.index < $1.index }        // recorded order (UI mirror may be out-of-order)
                 .filter { !$0.rejectedByUser }
                 .map { dir.appendingPathComponent($0.sourceFile) }
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
        let cropped = CoverageCrop.cropToCoverage(report.master, coverage: report.coverage)   // crop BEFORE balance
        let balanced = neutralize ? AutoStretch.neutralizeBackgroundAdditive(cropped) : cropped
        let totalExp = Double(report.stackedCount) * subExposureSeconds
        return FITSWriter.float32(width: balanced.width, height: balanced.height,
            channels: balanced.channels, pixels: balanced.pixels,
            metadata: metadata, stackCount: report.stackedCount, totalExposureSeconds: totalExp)
    }
}
