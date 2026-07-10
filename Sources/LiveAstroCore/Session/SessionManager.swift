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

    @discardableResult
    public func startSession(profile: SessionProfile, at date: Date = .init()) throws -> URL {
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
        manifest = SessionManifest(
            sessionId: id, targetName: profile.targetName, startTime: date, endTime: nil,
            subExposureSeconds: profile.subExposureSeconds, bortle: profile.bortle,
            locationLabel: profile.locationLabel, telescope: profile.telescope,
            camera: profile.camera, mount: profile.mount, filter: profile.filter,
            notes: profile.notes, snapshots: [])
        sessionDirectory = dir
        state = .running
        try persist()
        return dir
    }

    public func recordSnapshot(_ record: SnapshotRecord) throws {
        guard state == .running, manifest != nil else { throw SessionError.notRunning }
        manifest!.snapshots.append(record)
        try persist()
    }

    public func endSession(at date: Date = .init()) throws {
        guard state == .running, manifest != nil else { throw SessionError.notRunning }
        manifest!.endTime = date
        state = .ended
        try persist()
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
    private func persist() throws {
        guard let dir = sessionDirectory, let m = manifest else { return }
        let data = try ManifestCoding.encoder().encode(m)
        try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
