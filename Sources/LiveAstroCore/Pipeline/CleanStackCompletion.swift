import Foundation

/// Frozen post-session work. Retains registrations and the actual calibrator via its loader,
/// not the pipeline/online stack. Reuses GlobalRefiner's bounded loader pool across retries.
/// No overall 30s deadline here: this is an explicit operator request, cancellable between
/// processing steps. Individual file waits remain bounded; a pixel combine is not interruptible.
public final class CleanStackCompletion {
    public let status: CleanStackStatus
    public let directory: URL
    private let survivors: [SubRegistration]
    private let generation: Int
    private let kappa: Float
    private let budget: Int
    private let minSubs: Int
    private let metadata: SourceMetadata?
    private let neutralize: Bool
    private let fallbackSeconds: Double
    private let originalManifest: Data
    private let originalMasterDigest: String
    private let refiner: GlobalRefiner
    private let operationLock = NSLock()
    // The same persistence boundary used by the session manager; tests inject write failure.
    var manifestWriter: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }

    public enum CompletionError: Error, LocalizedError {
        case busy, sessionChanged
        case recoveryRequired(URL)
        public var errorDescription: String? {
            switch self {
            case .busy: return "A clean-stack completion is already running."
            case .sessionChanged: return "The saved session changed. The previous completion request cannot overwrite it."
            case .recoveryRequired(let directory):
                return "Saving failed and automatic rollback could not finish. Previous files are preserved at \(directory.path)."
            }
        }
    }

    init(directory: URL, survivors: [SubRegistration], generation: Int, kappa: Float,
         budget: Int, minSubs: Int, loader: FrameLoader, metadata: SourceMetadata?,
         neutralize: Bool, fallbackSeconds: Double, status: CleanStackStatus,
         accessLifetime: (any Sendable)? = nil) throws {
        self.status = status
        self.directory = directory
        self.survivors = survivors
        self.generation = generation
        self.kappa = kappa
        self.budget = budget
        self.minSubs = minSubs
        self.metadata = metadata
        self.neutralize = neutralize
        self.fallbackSeconds = fallbackSeconds
        originalManifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        originalMasterDigest = try Self.digest(directory.appendingPathComponent("master.fit"))
        refiner = GlobalRefiner(loader: loader, onLog: { _ in }, accessLifetime: accessLifetime)
    }

    public func finish(isCancelled: @escaping () -> Bool = { false },
                       progress: @escaping (String) -> Void = { _ in }) throws -> CleanStackCompletionResult {
        guard operationLock.try() else { throw CompletionError.busy }
        defer { operationLock.unlock() }
        if isCancelled() { throw CleanStackFailure.cancelled }
        try verifyUnchanged()
        var failure: CleanStackFailure?
        guard let result = refiner.refine(survivors: survivors, currentGeneration: generation,
            kappa: kappa, minSubs: minSubs, maxSampleBytes: budget, deadline: .distantFuture,
            isCancelled: isCancelled, onFailure: { failure = $0 }, progress: progress) else {
            throw failure ?? .combinationFailed
        }
        if isCancelled() { throw CleanStackFailure.cancelled }
        // Finishing means ALL frozen survivors, not merely another quorum. Never replace the
        // existing master with an incomplete retry when inputs are unavailable or changed.
        guard result.survivorCount == survivors.count, result.skipped == 0 else {
            throw failure ?? .unreadableInputs
        }
        guard let exposure = result.exposure else { throw CleanStackFailure.combinationFailed }
        let report = RestackReport(exposure: exposure, master: result.image,
            stackedCount: result.survivorCount, skippedMissing: 0, skippedMismatch: 0,
            unverifiedLegacy: survivors.contains { $0.contentDigest == nil }, coverage: result.coverage)
        let complete = CleanStackStatus(expectedCount: status.expectedCount, savedCount: result.survivorCount,
            expectedExposure: status.expectedExposure, savedExposure: exposure,
            savedClean: true, reason: nil)
        var manifest = try ManifestCoding.decoder().decode(SessionManifest.self, from: originalManifest)
        manifest.exposure = exposure
        manifest.subExposureSeconds = exposure.uniformSeconds ?? 0
        manifest.cleanStackStatus = complete
        // Online/session totals and historical snapshots stay historical. Only saved-master
        // exposure and clean-status change; the replay is deliberately not regenerated.
        let encodedManifest = try ManifestCoding.encoder().encode(manifest)
        let encodedMaster = RestackPlanning.encodeMaster(report, neutralize: neutralize,
            metadata: metadata, subExposureSeconds: fallbackSeconds)
        progress("Saving full clean master…")
        if isCancelled() { throw CleanStackFailure.cancelled }
        try verifyUnchanged()

        let fm = FileManager.default
        let backup = directory.appendingPathComponent("clean-stack-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        let masterURL = directory.appendingPathComponent("master.fit")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try fm.copyItem(at: masterURL, to: backup.appendingPathComponent("master.fit"))
        try originalManifest.write(to: backup.appendingPathComponent("manifest.json"))
        let summaryURL = directory.appendingPathComponent("session-summary.md")
        if fm.fileExists(atPath: summaryURL.path) {
            try fm.copyItem(at: summaryURL, to: backup.appendingPathComponent("session-summary.md"))
        }
        let temp = directory.appendingPathComponent(".clean-master-\(UUID().uuidString).fit")
        defer { try? fm.removeItem(at: temp) }
        try encodedMaster.write(to: temp)
        // Last cancellation boundary. Once replacement begins, finish/rollback the transaction;
        // a late Cancel must not strand master.fit and its manifest at different generations.
        if isCancelled() { throw CleanStackFailure.cancelled }
        var replaced = false
        do {
            try FileReplace.replaceItem(at: masterURL, withItemAt: temp)
            replaced = true
            try manifestWriter(encodedManifest, manifestURL)
        } catch {
            if replaced {
                do {
                    try fm.copyItem(at: backup.appendingPathComponent("master.fit"), to: temp)
                    try FileReplace.replaceItem(at: masterURL, withItemAt: temp)
                    try originalManifest.write(to: manifestURL, options: .atomic)
                } catch { throw CompletionError.recoveryRequired(backup) }
            }
            throw error
        }
        var warning: String?
        do { try SessionSummaryMarkdown.write(manifest: manifest, to: directory) }
        catch { warning = "Master and manifest saved, but session-summary.md could not be refreshed: \(error.localizedDescription)" }
        return CleanStackCompletionResult(report: report, status: complete, backupDirectory: backup, summaryWarning: warning)
    }

    private func verifyUnchanged() throws {
        guard try Data(contentsOf: directory.appendingPathComponent("manifest.json")) == originalManifest,
              try Self.digest(directory.appendingPathComponent("master.fit")) == originalMasterDigest else {
            throw CompletionError.sessionChanged
        }
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(Int.max),
              let digest = FileIdentity.contentDigest(handle: handle, size: Int(size)) else {
            throw CocoaError(.fileReadUnknown)
        }
        return digest
    }
}

public struct CleanStackCompletionResult {
    public let report: RestackReport
    public let status: CleanStackStatus
    public let backupDirectory: URL
    public let summaryWarning: String?
}
