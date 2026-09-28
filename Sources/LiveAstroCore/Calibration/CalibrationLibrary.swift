import Foundation
import Darwin

/// One reusable master calibration frame in the library (a dark or a bias).
/// The metadata is the match key; the pixels live in `fileName` on disk.
public struct MasterFrame: Codable, Equatable, Identifiable {
    public var id: UUID
    public var kind: MasterKind              // .dark or .bias (flats are session-scoped)
    public var camera: String
    public var gain: Double?
    public var exposureSeconds: Double?      // nil for bias (0 s)
    public var setTempC: Double?             // cooler set-point; nil if uncooled
    public var binning: Int?
    public var width: Int
    public var height: Int
    public var channels: Int
    public var frameCount: Int               // raw frames provided to the combine
    public var createdAt: Date
    public var fileName: String              // master-<id>.fit, relative to the library dir
    public var sourcePath: String?           // folder the raws came from, for Rebuild

    public init(id: UUID, kind: MasterKind, camera: String, gain: Double?, exposureSeconds: Double?,
                setTempC: Double?, binning: Int?, width: Int, height: Int, channels: Int,
                frameCount: Int, createdAt: Date, fileName: String, sourcePath: String?) {
        self.id = id; self.kind = kind; self.camera = camera; self.gain = gain
        self.exposureSeconds = exposureSeconds; self.setTempC = setTempC; self.binning = binning
        self.width = width; self.height = height; self.channels = channels
        self.frameCount = frameCount; self.createdAt = createdAt
        self.fileName = fileName; self.sourcePath = sourcePath
    }

    /// A master's on-disk name must be a plain basename inside the library — never a path that could
    /// traverse out (`../…`, an absolute path, or embedded separators).
    static func isSafeBasename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && name == (name as NSString).lastPathComponent
    }

    // Versioned-tolerant decode: only id/kind/camera/fileName are truly required (the record is
    // useless without them). Fields added over time (channels, frameCount, dims, createdAt) DEFAULT
    // when absent, so an older-schema index entry is SALVAGED rather than silently dropped by the
    // per-entry tolerant decode in `all()` (which would then be pruned on the next write). Encoding
    // stays auto-synthesized (always writes the current, complete schema).
    private enum CodingKeys: String, CodingKey {
        case id, kind, camera, gain, exposureSeconds, setTempC, binning
        case width, height, channels, frameCount, createdAt, fileName, sourcePath
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(MasterKind.self, forKey: .kind)
        camera = try c.decode(String.self, forKey: .camera)
        fileName = try c.decode(String.self, forKey: .fileName)
        // SECURITY: fileName drives load / rebuild-overwrite / remove-delete. Require the CANONICAL
        // name master-<id>.fit — this both blocks path traversal ("../../evil.fit") AND prevents one
        // entry from aliasing another's master file (a corrupt index pointing A's fileName at B's
        // file, which would load/overwrite/delete B under A's identity — all still "inside" the
        // library). The tolerant per-entry decode in all() then skips any record that fails this.
        guard MasterFrame.isSafeBasename(fileName), fileName == "master-\(id.uuidString).fit" else {
            throw DecodingError.dataCorruptedError(forKey: .fileName, in: c,
                debugDescription: "master fileName must be the canonical master-<id>.fit: \(fileName)")
        }
        gain = try c.decodeIfPresent(Double.self, forKey: .gain)
        exposureSeconds = try c.decodeIfPresent(Double.self, forKey: .exposureSeconds)
        setTempC = try c.decodeIfPresent(Double.self, forKey: .setTempC)
        binning = try c.decodeIfPresent(Int.self, forKey: .binning)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? 1
        frameCount = try c.decodeIfPresent(Int.self, forKey: .frameCount) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}

/// On-disk library of reusable master darks/bias. Masters build once per camera+
/// settings and persist across sessions; flats are NOT stored here (session-scoped).
///
/// Layout: `<baseDir>/index.json` (array of MasterFrame) + one `master-<id>.fit`
/// per entry. Default baseDir is Application Support; a test seam overrides it.
public final class CalibrationLibrary: Sendable {
    public enum LibraryError: Error, Equatable { case noSourceFolder, noFramesInSource, unsafeFileName }

    private let baseDir: URL
    private let beforeRebuild: (@Sendable () -> Void)?
    private let beforeAdd: (@Sendable () -> Void)?
    // Pixel work is deliberately outside this lock. Only short index
    // read/modify/write transactions and the final master replacement hold it.
    private let indexLock = NSRecursiveLock()

    /// - Parameter baseDirectory: test seam. When nil, uses Application Support.
    public init(baseDirectory: URL? = nil) {
        self.baseDir = baseDirectory ?? Self.defaultDirectory()
        self.beforeRebuild = nil
        self.beforeAdd = nil
    }

    /// Deterministic scheduling seam; never installed by production callers.
    init(baseDirectory: URL, beforeRebuild: @escaping @Sendable () -> Void,
         beforeAdd: (@Sendable () -> Void)? = nil) {
        self.baseDir = baseDirectory
        self.beforeRebuild = beforeRebuild
        self.beforeAdd = beforeAdd
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstroStudio/CalibrationLibrary", isDirectory: true)
    }

    private var indexURL: URL { baseDir.appendingPathComponent("index.json") }

    /// Resolve a master's on-disk URL, GUARANTEEING it stays inside the library root. Returns nil for
    /// an unsafe/traversing fileName — defense-in-depth beyond the decode-time `isSafeBasename` check,
    /// so load/rebuild/remove can never touch a file outside the library.
    private func masterURL(for fileName: String) -> URL? {
        guard MasterFrame.isSafeBasename(fileName) else { return nil }
        let url = baseDir.appendingPathComponent(fileName).standardizedFileURL
        guard url.path.hasPrefix(baseDir.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    /// All library entries (empty if none / unreadable). Decodes entry-by-entry and SKIPS any single
    /// malformed/legacy entry rather than failing the whole array — one bad record must not hide
    /// every good master.
    public func all() -> [MasterFrame] {
        indexLock.lock(); defer { indexLock.unlock() }
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoded: [MasterFrame]
        // Fast path: a fully-valid array.
        if let frames = try? JSONDecoder().decode([MasterFrame].self, from: data) {
            decoded = frames
        } else {
            // Tolerant path: decode each element independently, dropping the ones that fail.
            struct Tolerant: Decodable {
                let frame: MasterFrame?
                init(from decoder: Decoder) throws {
                    frame = try? decoder.singleValueContainer().decode(MasterFrame.self)
                }
            }
            guard let wrapped = try? JSONDecoder().decode([Tolerant].self, from: data) else { return [] }
            decoded = wrapped.compactMap(\.frame)
        }
        // De-duplicate by id (a corrupt index could repeat one) — keep the first occurrence. The
        // canonical-fileName invariant already guarantees distinct ids map to distinct files.
        var seen = Set<UUID>()
        return decoded.filter { seen.insert($0.id).inserted }
    }

    /// Build a master from `fitsURLs` and add it to the library. `bias` is only
    /// used when building a flat/dark-flat offset — irrelevant for dark/bias masters.
    /// An explicit source keeps the authorized folder identity even if enumeration canonicalizes it.
    @discardableResult
    public func add(kind: MasterKind, camera: String, gain: Double?, exposureSeconds: Double?,
                    setTempC: Double?, binning: Int?, fitsURLs: [URL],
                    bias: AstroImage? = nil, sourceDirectory: URL? = nil,
                    failOnReadError: Bool = false) throws -> MasterFrame {
        let built = try MasterBuilder.combineDetailed(fitsURLs: fitsURLs, kind: kind, bias: bias,
                                                       failOnReadError: failOnReadError)
        let master = built.image
        let id = UUID()
        beforeAdd?()
        let fileName = "master-\(id.uuidString).fit"
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try MasterBuilder.save(master, to: baseDir.appendingPathComponent(fileName))
        let frame = MasterFrame(
            id: id, kind: kind, camera: camera, gain: gain, exposureSeconds: exposureSeconds,
            setTempC: setTempC, binning: binning, width: master.width, height: master.height,
            // frameCount reflects frames that ACTUALLY contributed (readable + matching dims), not
            // the input count — a corrupt/odd-sized file is skipped and must not inflate the ×N.
            channels: master.channels, frameCount: built.contributingCount, createdAt: Date(),
            fileName: fileName, sourcePath: sourceDirectory?.path ?? fitsURLs.first?.deletingLastPathComponent().path)
        try indexLock.withLock {
            var frames = all(); frames.append(frame); try writeIndex(frames)
        }
        return frame
    }

    /// Re-combine an entry from its remembered source folder, replacing the master
    /// in place (same id/fileName) and refreshing dimensions/count/date.
    /// The caller may supply a bookmark-resolved moved source; remember it after successful rebuild.
    public func rebuild(id: UUID, bias: AstroImage? = nil, sourceDirectory: URL? = nil,
                        failOnReadError: Bool = false) throws {
        guard let captured = all().first(where: { $0.id == id }) else { return }
        guard let src = captured.sourcePath else { throw LibraryError.noSourceFolder }
        beforeRebuild?()
        let folder = sourceDirectory ?? URL(fileURLWithPath: src, isDirectory: true)
        let urls = failOnReadError ? try Self.fitsFilesRequiringAccess(in: folder) : Self.fitsFiles(in: folder)
        guard !urls.isEmpty else { throw LibraryError.noFramesInSource }
        let built = try MasterBuilder.combineDetailed(fitsURLs: urls, kind: captured.kind, bias: bias,
                                                       failOnReadError: failOnReadError)
        let master = built.image
        let staged = baseDir.appendingPathComponent(".rebuild-\(UUID().uuidString).fit")
        defer { try? FileManager.default.removeItem(at: staged) }
        try MasterBuilder.save(master, to: staged)
        try indexLock.withLock {
            var frames = all()
            // Removal wins over an in-flight rebuild; never resurrect its entry/file.
            guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }
            guard let masterURL = masterURL(for: frames[idx].fileName) else { throw LibraryError.unsafeFileName }
            // Encoding and the large write finished outside the index lock.
            // Same-directory rename publishes the complete file atomically.
            guard rename(staged.path, masterURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            frames[idx].width = master.width; frames[idx].height = master.height
            frames[idx].channels = master.channels; frames[idx].frameCount = built.contributingCount
            frames[idx].createdAt = Date()
            if frames[idx].sourcePath == captured.sourcePath, let sourceDirectory {
                frames[idx].sourcePath = sourceDirectory.path
            }
            try writeIndex(frames)
        }
    }

    /// Persist bookmark-resolved provenance independently of a later pixel build.
    /// Callers authorize these directories; this does not grant access or claim a
    /// successful rebuild. Preserve every other field and avoid rewriting unchanged indexes.
    @discardableResult
    public func updateSourceDirectories(_ directories: [UUID: URL],
                                        expectedSourcePaths: [UUID: String]? = nil) throws -> [MasterFrame] {
        indexLock.lock(); defer { indexLock.unlock() }
        var frames = all()
        var changed = false
        for idx in frames.indices {
            guard let directory = directories[frames[idx].id], frames[idx].sourcePath != directory.path else { continue }
            if let expectedSourcePaths, frames[idx].sourcePath != expectedSourcePaths[frames[idx].id] { continue }
            frames[idx].sourcePath = directory.path
            changed = true
        }
        if changed { try writeIndex(frames) }
        return frames
    }

    /// Remove an entry and its master file.
    public func remove(id: UUID) throws {
        indexLock.lock(); defer { indexLock.unlock() }
        var frames = all()
        guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }
        let f = frames.remove(at: idx)
        if let url = masterURL(for: f.fileName) { try? FileManager.default.removeItem(at: url) }
        try writeIndex(frames)
    }

    /// Load an entry's master pixels (nil if the file is missing/unreadable).
    public func master(for frame: MasterFrame) -> AstroImage? {
        guard let url = masterURL(for: frame.fileName) else { return nil }
        return try? MasterBuilder.load(url)
    }

    // MARK: - Private

    private func writeIndex(_ frames: [MasterFrame]) throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(frames).write(to: indexURL, options: .atomic)
    }

    public static func fitsFiles(in folder: URL) -> [URL] {
        (try? fitsFilesRequiringAccess(in: folder)) ?? []
    }

    public static func fitsFilesRequiringAccess(in folder: URL) throws -> [URL] {
        let exts: Set<String> = ["fit", "fits"]
        let items: [URL]
        do { items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
        catch { throw CalibrationReadError(url: folder, underlying: error) }
        return items.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
