import Foundation

public enum CameraShareKind: String, Sendable, CaseIterable {
    case seestar, asiair
    public var displayName: String { self == .seestar ? "Seestar" : "ASIAIR" }
}

public struct CameraShareTarget: Sendable {
    public let directory: URL
    public let name: String
    public let exposure: Double?
    public let fileExtension: String
}

/// Discovery inside one operator-authorized mounted share. Unlike broad direct-edition
/// discovery, access/listing failures must propagate, not masquerade as no targets.
public enum CameraShareDiscovery {
    public static func detect(in share: URL, kind: CameraShareKind) throws -> CameraShareTarget? {
        let fm = FileManager.default
        let root = share.standardizedFileURL.resolvingSymlinksInPath()
        _ = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let layout = try contained(root.appendingPathComponent(kind == .seestar ? "MyWorks" : "Autorun/Light"), in: root)
        let entries = try fm.contentsOfDirectory(at: layout,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
        var candidates: [(URL, Date)] = []
        for entry in entries {
            try Task.checkCancellation()
            if kind == .seestar && !entry.lastPathComponent.hasSuffix("_sub") { continue }
            let directory = try contained(entry, in: root)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { continue }
            if kind == .asiair {
                let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
                var hasFITS = false
                for child in children where ["fit", "fits"].contains(child.pathExtension.lowercased()) {
                    let file = try contained(child, in: root)
                    if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { hasFITS = true }
                }
                guard hasFITS else { continue }
            }
            candidates.append((directory, values.contentModificationDate ?? .distantPast))
        }
        guard let best = candidates.max(by: { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 < $1.1 })?.0 else { return nil }
        try Task.checkCancellation()
        if kind == .seestar {
            let names = try fm.contentsOfDirectory(atPath: best.path).filter { ($0 as NSString).pathExtension.lowercased() == "fit" }
            let newest = names.max {
                (SeestarDetector.parseCaptureTimestamp(fromFilename: $0) ?? "") <
                (SeestarDetector.parseCaptureTimestamp(fromFilename: $1) ?? "")
            }
            return CameraShareTarget(directory: best, name: String(best.lastPathComponent.dropLast(4)),
                exposure: newest.flatMap(SeestarDetector.parseExposure(fromFilename:)), fileExtension: "fit")
        }
        let metadata = try newestASIAIRMetadata(in: best, root: root)
        return CameraShareTarget(directory: best, name: best.lastPathComponent,
            exposure: metadata.exposure, fileExtension: metadata.fileExtension)
    }

    /// A partially written FITS header is normal during capture. A filesystem
    /// denial is not: propagating it avoids silently starting the wrong relay glob.
    /// The direct edition's permissive metadata helper is deliberately unchanged.
    private static func newestASIAIRMetadata(in directory: URL, root: URL) throws -> (exposure: Double?, fileExtension: String) {
        let items = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
        var files: [(url: URL, modified: Date)] = []
        for item in items where ["fit", "fits"].contains(item.pathExtension.lowercased()) {
            let url = try contained(item, in: root)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values.isRegularFile == true { files.append((url, values.contentModificationDate ?? .distantPast)) }
        }
        files.sort { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified }
        guard let newest = files.first else { throw CocoaError(.fileReadNoSuchFile) }
        for file in files {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 256 * 1024) ?? Data()
            guard let header = try? FITSReader.readHeader(prefix) else { continue }
            // Older headers may supply exposure while the latest capture is
            // incomplete, but must not change which extension the relay watches.
            return (SourceMetadata(fitsKeywords: header.keywords).exposureSeconds, newest.url.pathExtension.lowercased())
        }
        return (nil, newest.url.pathExtension.lowercased())
    }

    private static func contained(_ url: URL, in root: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathComponents.starts(with: root.pathComponents) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        return resolved
    }
}
