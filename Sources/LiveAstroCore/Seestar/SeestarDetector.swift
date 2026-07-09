import Foundation

/// Finds the active Seestar capture folder: scans <volumesRoot>/ * /MyWorks/ * _sub
/// and returns the newest-modified one (tonight's target).
public enum SeestarDetector {
    public struct Found: Equatable {
        public let subDir: URL
        public let target: String
        public let subExposure: Double?
        public init(subDir: URL, target: String, subExposure: Double?) {
            self.subDir = subDir; self.target = target; self.subExposure = subExposure
        }
    }

    public static func detect(volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> Found? {
        let fm = FileManager.default
        var candidates: [(url: URL, mod: Date)] = []
        let vols = (try? fm.contentsOfDirectory(at: volumesRoot, includingPropertiesForKeys: nil)) ?? []
        for vol in vols {
            let works = vol.appendingPathComponent("MyWorks")
            let subs = (try? fm.contentsOfDirectory(at: works, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for sub in subs where sub.lastPathComponent.hasSuffix("_sub") {
                let mod = (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                candidates.append((sub, mod))
            }
        }
        guard let best = candidates.max(by: { $0.mod < $1.mod }) else { return nil }
        let target = String(best.url.lastPathComponent.dropLast("_sub".count))
        let sample = ((try? fm.contentsOfDirectory(atPath: best.url.path)) ?? []).first { $0.hasSuffix(".fit") }
        return Found(subDir: best.url, target: target,
                     subExposure: sample.flatMap(parseExposure(fromFilename:)))
    }

    /// Parse "..._10.0s_..." → 10.0
    public static func parseExposure(fromFilename name: String) -> Double? {
        // find a token of the form <digits(.digits)?>s bounded by underscores
        for token in name.split(separator: "_") where token.hasSuffix("s") {
            let num = token.dropLast()
            if let v = Double(num) { return v }
        }
        return nil
    }
}
