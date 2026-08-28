import Foundation

/// Failure modes for `RestackCoordinator.restack`. Missing/unreadable raw files are NOT
/// an error — they're counted in `RestackReport.skippedMissing` and the restack proceeds
/// with the rest, mirroring how the live/import pipeline logs-and-skips a bad frame
/// rather than aborting the whole session (see `FolderFrameSource.frame(for:log:)`).
public enum RestackError: Error, Equatable {
    /// Every raw sub was either excluded or failed to load — nothing to stack.
    case noSurvivingSubs
    /// Frames survived and loaded, but none had enough detected stars to seed the
    /// engine's reference frame (`engine.currentStack() == nil` after processing all of
    /// them). `surviving` is the count of frames actually handed to the engine;
    /// `needed` is `StackEngine.minimumSeedStars`.
    case belowSeedMinimum(surviving: Int, needed: Int)
}

/// Result of a successful restack: the rebuilt master plus accounting so the caller
/// (Task 8) can report what happened without re-deriving it.
public struct RestackReport {
    public let master: AstroImage
    /// `engine.stackFrameCount` after processing — frames actually folded into the
    /// current stack (the seed frame plus every frame that registered against it).
    public let stackedCount: Int
    /// Kept (non-excluded) URLs that failed to load as a `RawFrame` (missing file,
    /// unreadable, corrupt, etc.) — skipped rather than aborting the restack.
    public let skippedMissing: Int
    /// Per-pixel coverage (frame-count) map of the rebuilt stack, read from
    /// `engine.currentCoverage()` at the same point as `master`. Lets the app layer
    /// crop the written `master.fit` to its covered region (parity with the live
    /// pipeline's master write). Nil when the engine has no coverage. Additive — the
    /// `master` pixels are unchanged, so the golden restack test stays valid.
    public let coverage: [Float]?
}

/// The pure core of "re-stack the master from raw subs minus a flagged set."
///
/// Given the ordered list of raw sub URLs for a session and the set of source-file
/// basenames to exclude, this drives a **fresh** `StackEngine` through the exact same
/// sequence the native live/import pipeline uses (`SessionPipeline.handleNative`):
/// call `engine.process(frame)` on every surviving, loadable frame in original order,
/// with NO separate seed call — the engine auto-seeds on the first frame that clears
/// `seedMinStars` (see `StackEngine.processDetailedLocked`'s `referenceSize == nil`
/// branch). Matching that sequence exactly (same loader, same order, same call) is what
/// makes a restack byte-identical to a fresh stack of the same survivors — the golden
/// property this feature depends on (`RestackCoordinatorTests.
/// testRestackEqualsFreshStackOfSurvivors`).
///
/// URL resolution (session `subFrames` / relay folder → concrete file URLs) and applying
/// the resulting master live in the app layer (Task 8) — kept out of this function so it
/// stays a pure, easily golden-tested transform.
public enum RestackCoordinator {
    /// - Parameter prepare: Applied to every loaded raw frame BEFORE `engine.process(...)`,
    ///   including the seed frame — every frame goes through the same `prepare`. The live
    ///   pipeline applies a calibrator (darks/flats/bias) before stacking
    ///   (`SessionPipeline.handleNative`); without this, a restack of a calibrated session
    ///   would overwrite a calibrated master.fit with an uncalibrated one. Defaults to
    ///   identity so existing callers/tests are unaffected.
    public static func restack(rawURLs: [URL], excludingSourceFiles: Set<String>,
                               makeEngine: () -> StackEngine,
                               prepare: (RawFrame) -> RawFrame = { $0 }) throws -> RestackReport {
        let kept = rawURLs.filter { !excludingSourceFiles.contains($0.lastPathComponent) }

        // Stream: load → prepare → process one frame at a time, keeping only a single
        // RawFrame resident. Buffering all survivors first cost gigabytes for 26MP × N.
        // The load/prepare/process sequence and order are identical to the buffered form,
        // so a restack stays byte-identical to a fresh stack of the same survivors (the
        // golden property `testRestackEqualsFreshStackOfSurvivors` pins).
        let engine = makeEngine()
        var loadedCount = 0
        var skippedMissing = 0
        for url in kept {
            guard let frame = try? FolderFrameSource.loadRawFrame(url: url) else { skippedMissing += 1; continue }
            _ = engine.process(prepare(frame))
            loadedCount += 1
        }
        guard loadedCount > 0 else { throw RestackError.noSurvivingSubs }

        guard let master = engine.currentStack() else {
            throw RestackError.belowSeedMinimum(surviving: loadedCount, needed: engine.minimumSeedStars)
        }
        return RestackReport(master: master, stackedCount: engine.stackFrameCount,
                             skippedMissing: skippedMissing, coverage: engine.currentCoverage())
    }
}
