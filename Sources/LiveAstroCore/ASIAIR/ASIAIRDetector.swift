import Foundation

/// Finds the active ASIAIR capture folder: scans <volumesRoot>/*/Autorun/Light/<TARGET>/
/// and returns the newest-modified target folder that contains at least one
/// .fit/.fits sub. `target` is the folder name; `subExposure` and
/// `subFileExtension` come from the newest FITS header via LiveSourceMetadata.
///
/// Mirrors `SeestarDetector` but for the ASIAIR's Autorun/Light layout. Unlike
/// Seestar's `_sub` suffix, ASIAIR target folders have no marker, so a
/// "contains FITS" guard is what distinguishes a real capture folder from an
/// empty leftover.
public enum ASIAIRDetector {
    public struct Found: Equatable {
        public let subDir: URL
        public let target: String
        public let subExposure: Double?
        public let subFileExtension: String
        public init(subDir: URL, target: String, subExposure: Double?, subFileExtension: String) {
            self.subDir = subDir
            self.target = target
            self.subExposure = subExposure
            self.subFileExtension = subFileExtension
        }
    }

    public static func detect(volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> Found? {
        let fm = FileManager.default
        var candidates: [(url: URL, mod: Date)] = []
        let vols = (try? fm.contentsOfDirectory(at: volumesRoot, includingPropertiesForKeys: nil)) ?? []
        for vol in vols {
            let lightRoot = vol.appendingPathComponent("Autorun").appendingPathComponent("Light")
            let targets = (try? fm.contentsOfDirectory(
                at: lightRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
            for target in targets {
                let isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir, folderContainsFITS(target, fm: fm) else { continue }
                let mod = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append((target, mod))
            }
        }
        guard let best = candidates.max(by: { $0.mod < $1.mod }) else { return nil }
        let meta = LiveSourceMetadata.newestFITSMetadata(inFolder: best.url)
        return Found(subDir: best.url,
                     target: best.url.lastPathComponent,
                     subExposure: meta?.exposureSeconds,
                     subFileExtension: meta?.fileExtension ?? "fit")
    }

    private static func folderContainsFITS(_ folder: URL, fm: FileManager) -> Bool {
        let items = (try? fm.contentsOfDirectory(at: folder,
                        includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return items.contains { url in
            guard ["fit", "fits"].contains(url.pathExtension.lowercased()) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        }
    }
}
