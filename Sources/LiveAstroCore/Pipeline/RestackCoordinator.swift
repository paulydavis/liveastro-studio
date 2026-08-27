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
    public static func restack(rawURLs: [URL], excludingSourceFiles: Set<String>,
                               makeEngine: () -> StackEngine) throws -> RestackReport {
        let kept = rawURLs.filter { !excludingSourceFiles.contains($0.lastPathComponent) }

        var frames: [RawFrame] = []
        var skippedMissing = 0
        for url in kept {
            if let frame = try? FolderFrameSource.loadRawFrame(url: url) {
                frames.append(frame)
            } else {
                skippedMissing += 1
            }
        }
        guard !frames.isEmpty else { throw RestackError.noSurvivingSubs }

        let engine = makeEngine()
        for frame in frames {
            _ = engine.process(frame)
        }

        guard let master = engine.currentStack() else {
            throw RestackError.belowSeedMinimum(surviving: frames.count, needed: engine.minimumSeedStars)
        }
        return RestackReport(master: master, stackedCount: engine.stackFrameCount, skippedMissing: skippedMissing)
    }
}
