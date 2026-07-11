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
        // Parse the exposure from the NEWEST .fit so a folder that ended up with
        // mixed exposures (e.g. a 30s → 20s restart) reports the current length.
        let fitNames = ((try? fm.contentsOfDirectory(atPath: best.url.path)) ?? [])
            .filter { ($0 as NSString).pathExtension.lowercased() == "fit" }
        let newestName = fitNames.max { a, b in
            (parseCaptureTimestamp(fromFilename: a) ?? "") < (parseCaptureTimestamp(fromFilename: b) ?? "")
        }
        return Found(subDir: best.url, target: target,
                     subExposure: newestName.flatMap(parseExposure(fromFilename:)))
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

    /// Extract the sortable capture stamp "YYYYMMDD-HHMMSS" from a Seestar
    /// filename like "Light_NGC 6960_30.0s_LP_20260711-013530.fit". nil if absent.
    /// The token sorts chronologically as a plain string.
    public static func parseCaptureTimestamp(fromFilename name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        for token in base.split(separator: "_") {
            let t = String(token)
            // 8 digits, '-', 6 digits
            let parts = t.split(separator: "-")
            if parts.count == 2, parts[0].count == 8, parts[1].count == 6,
               parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber) {
                return t
            }
        }
        return nil
    }
}
