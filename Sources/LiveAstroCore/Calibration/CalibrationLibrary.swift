import Foundation

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
}

/// On-disk library of reusable master darks/bias. Masters build once per camera+
/// settings and persist across sessions; flats are NOT stored here (session-scoped).
///
/// Layout: `<baseDir>/index.json` (array of MasterFrame) + one `master-<id>.fit`
/// per entry. Default baseDir is Application Support; a test seam overrides it.
public final class CalibrationLibrary: Sendable {
    public enum LibraryError: Error, Equatable { case noSourceFolder, noFramesInSource }

    private let baseDir: URL

    /// - Parameter baseDirectory: test seam. When nil, uses Application Support.
    public init(baseDirectory: URL? = nil) {
        self.baseDir = baseDirectory ?? Self.defaultDirectory()
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstroStudio/CalibrationLibrary", isDirectory: true)
    }

    private var indexURL: URL { baseDir.appendingPathComponent("index.json") }

    /// All library entries (empty if none / unreadable).
    public func all() -> [MasterFrame] {
        guard let data = try? Data(contentsOf: indexURL),
              let frames = try? JSONDecoder().decode([MasterFrame].self, from: data) else { return [] }
        return frames
    }

    /// Build a master from `fitsURLs` and add it to the library. `bias` is only
    /// used when building a flat/dark-flat offset — irrelevant for dark/bias masters.
    @discardableResult
    public func add(kind: MasterKind, camera: String, gain: Double?, exposureSeconds: Double?,
                    setTempC: Double?, binning: Int?, fitsURLs: [URL],
                    bias: AstroImage? = nil) throws -> MasterFrame {
        let built = try MasterBuilder.combineDetailed(fitsURLs: fitsURLs, kind: kind, bias: bias)
        let master = built.image
        let id = UUID()
        let fileName = "master-\(id.uuidString).fit"
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try MasterBuilder.save(master, to: baseDir.appendingPathComponent(fileName))
        let frame = MasterFrame(
            id: id, kind: kind, camera: camera, gain: gain, exposureSeconds: exposureSeconds,
            setTempC: setTempC, binning: binning, width: master.width, height: master.height,
            // frameCount reflects frames that ACTUALLY contributed (readable + matching dims), not
            // the input count — a corrupt/odd-sized file is skipped and must not inflate the ×N.
            channels: master.channels, frameCount: built.contributingCount, createdAt: Date(),
            fileName: fileName, sourcePath: fitsURLs.first?.deletingLastPathComponent().path)
        var frames = all(); frames.append(frame); try writeIndex(frames)
        return frame
    }

    /// Re-combine an entry from its remembered source folder, replacing the master
    /// in place (same id/fileName) and refreshing dimensions/count/date.
    public func rebuild(id: UUID, bias: AstroImage? = nil) throws {
        var frames = all()
        guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }
        guard let src = frames[idx].sourcePath else { throw LibraryError.noSourceFolder }
        let urls = Self.fitsFiles(in: URL(fileURLWithPath: src, isDirectory: true))
        guard !urls.isEmpty else { throw LibraryError.noFramesInSource }
        let built = try MasterBuilder.combineDetailed(fitsURLs: urls, kind: frames[idx].kind, bias: bias)
        let master = built.image
        try MasterBuilder.save(master, to: baseDir.appendingPathComponent(frames[idx].fileName))
        frames[idx].width = master.width; frames[idx].height = master.height
        frames[idx].channels = master.channels; frames[idx].frameCount = built.contributingCount
        frames[idx].createdAt = Date()
        try writeIndex(frames)
    }

    /// Remove an entry and its master file.
    public func remove(id: UUID) throws {
        var frames = all()
        guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }
        let f = frames.remove(at: idx)
        try? FileManager.default.removeItem(at: baseDir.appendingPathComponent(f.fileName))
        try writeIndex(frames)
    }

    /// Load an entry's master pixels (nil if the file is missing/unreadable).
    public func master(for frame: MasterFrame) -> AstroImage? {
        try? MasterBuilder.load(baseDir.appendingPathComponent(frame.fileName))
    }

    // MARK: - Private

    private func writeIndex(_ frames: [MasterFrame]) throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(frames).write(to: indexURL, options: .atomic)
    }

    public static func fitsFiles(in folder: URL) -> [URL] {
        let exts: Set<String> = ["fit", "fits"]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
