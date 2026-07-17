import Foundation

public enum SessionError: Error, Equatable {
    case notRunning
    case alreadyRunning
}

public final class SessionManager {
    public enum State: Equatable { case idle, running, ended }

    public private(set) var state: State = .idle
    public private(set) var manifest: SessionManifest?
    public private(set) var sessionDirectory: URL?
    private let rootDirectory: URL

    /// Injectable manifest-write seam (F3 / spec §Seams — the SECOND pre-approved seam).
    /// PRODUCTION LEAVES THIS nil: `persist` then uses the built-in atomic write path
    /// (`Data(.atomic)` = temp+rename), byte-identical to the pre-seam behavior. It exists ONLY so
    /// the `manifest-midwrite` crash cell can block at the pre-publish point of a challenged write
    /// (stage full bytes to a same-dir temp, touch a readiness flag, then block forever — never
    /// publish) — so the SIGKILL that waits on the flag lands DETERMINISTICALLY between staging and
    /// publication, and the aftermath provably shows the prior published version intact beside the
    /// complete, closed, unpublished staged temp. A block-point cannot be interposed inside
    /// production `Data(.atomic)`; the injected writer performs byte-identical staging steps. When
    /// set, the closure is responsible for performing the actual write of `data` to `url`.
    public var manifestWriter: ((Data, URL) throws -> Void)?

    public init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

    public var acceptedCount: Int { manifest?.snapshots.count ?? 0 }
    public var estimatedIntegrationSeconds: Double {
        Double(acceptedCount) * (manifest?.subExposureSeconds ?? 0)
    }

    // Fixed format/locale/calendar make this formatter immutable after setup,
    // so a single shared instance is safe to reuse.
    private static let sessionIdDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        return fmt
    }()

    public static func sessionId(date: Date, targetName: String) -> String {
        var slug = targetName.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        if slug.isEmpty { slug = "session" }
        return "\(Self.sessionIdDateFormatter.string(from: date))-\(String(slug.prefix(24)))"
    }

    /// `masterExpected` (review11 finding 2): whether this session PROMISES a durable
    /// master.fit at end — decided by the CALLER's session semantics at start and immutable
    /// thereafter (SessionPipeline passes true for native stacking, false for watcher mode).
    /// Defaults to false: a bare SessionManager never writes a master itself — only the
    /// native pipeline does — so a standalone manager session honestly promises none.
    @discardableResult
    public func startSession(profile: SessionProfile, at date: Date = .init(),
                             masterExpected: Bool = false) throws -> URL {
        // Intentional: an ended manager may start a fresh session (watcher-mode reuse).
        guard state != .running else { throw SessionError.alreadyRunning }
        let baseId = Self.sessionId(date: date, targetName: profile.targetName)
        var id = baseId
        var suffix = 1
        while FileManager.default.fileExists(
            atPath: rootDirectory.appendingPathComponent(id, isDirectory: true).path) {
            suffix += 1
            id = "\(baseId)-\(suffix)"
        }
        let dir = rootDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        // Write-then-commit: build the proposed manifest, persist it, and only mutate
        // in-memory state once the write succeeds. A failed persist must leave the manager
        // idle (no half-started session that disk doesn't reflect).
        let proposed = SessionManifest(
            sessionId: id, targetName: profile.targetName, startTime: date, endTime: nil,
            subExposureSeconds: profile.subExposureSeconds, bortle: profile.bortle,
            locationLabel: profile.locationLabel, telescope: profile.telescope,
            camera: profile.camera, mount: profile.mount, filter: profile.filter,
            notes: profile.notes, snapshots: [], masterExpected: masterExpected)
        try persist(proposed, to: dir)
        manifest = proposed
        sessionDirectory = dir
        state = .running
        return dir
    }

    public func recordSnapshot(_ record: SnapshotRecord) throws {
        guard state == .running, var proposed = manifest, let dir = sessionDirectory else {
            throw SessionError.notRunning
        }
        // Write-then-commit: persist the proposed manifest first; only append in memory
        // once the write lands, so a failed write can't leave a counted-but-unpersisted frame.
        proposed.snapshots.append(record)
        try persist(proposed, to: dir)
        manifest = proposed
    }

    public func endSession(at date: Date = .init(),
                           finalization: SessionFinalizationFacts? = nil) throws {
        guard state == .running, var proposed = manifest, let dir = sessionDirectory else {
            throw SessionError.notRunning
        }
        // Write-then-commit: persist the ended manifest first; only mark ended once it lands,
        // so a failed write can't leave the manager ended with an unpersisted endTime.
        proposed.endTime = date
        proposed.finalizationFacts = finalization
        try persist(proposed, to: dir)
        manifest = proposed
        state = .ended
    }

    /// Fill blank manifest metadata from the source header. User-entered values always win.
    /// No-op if there is no active manifest.
    public func fillMissingMetadata(from meta: SourceMetadata) {
        guard manifest != nil else { return }
        if manifest!.camera.isEmpty, let v = meta.instrument { manifest!.camera = v }
        if manifest!.telescope.isEmpty, let v = meta.telescope { manifest!.telescope = v }
        if manifest!.filter.isEmpty, let v = meta.filter { manifest!.filter = v }
    }

    /// Atomic write: temp file + rename via Data(.atomic). Crash loses at most the in-flight update (spec §7).
    /// Takes the manifest + directory explicitly so callers can persist a PROPOSED manifest
    /// before committing it to in-memory state (write-then-commit — see startSession/record/end).
    private func persist(_ m: SessionManifest, to dir: URL) throws {
        let data = try ManifestCoding.encoder().encode(m)
        let url = dir.appendingPathComponent("manifest.json")
        // Seam (F3): production has no injected writer → the default atomic write runs, unchanged.
        if let writer = manifestWriter {
            try writer(data, url)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
