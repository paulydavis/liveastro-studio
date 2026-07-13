// Sources/LiveAstroCore/Live/RelayPruner.swift
import Foundation

/// Age-based cleanup of relay staging sessions (spec: relay auto-prune).
/// Relay dirs are named "<target>-YYYY-MM-DD[-<exp>s]" by the app; the session
/// date is parsed from the NAME (relaying touches mtimes, so mtime is unreliable).
/// Deletes only immediate, name-dated subdirectories of `root` that are STRICTLY
/// older than `now − olderThanDays` (date granularity). Anything unparseable, any
/// plain file, and the `excluding` dir (the active/incoming session) are never
/// touched. Best-effort and non-throwing; every removal is reported for logging.
public enum RelayPruner {
    public struct Removed: Equatable {
        public let name: String
        public let bytes: Int64
        public init(name: String, bytes: Int64) { self.name = name; self.bytes = bytes }
    }

    public static func prune(root: URL, olderThanDays: Int, now: Date = Date(),
                             excluding: URL? = nil) -> [Removed] {
        guard olderThanDays > 0 else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return [] }
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -olderThanDays,
                                    to: cal.startOfDay(for: now)) else { return [] }
        let excluded = excluding?.standardizedFileURL.path
        var removed: [Removed] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  entry.standardizedFileURL.path != excluded,
                  let session = sessionDate(fromName: entry.lastPathComponent),
                  session < cutoff else { continue }
            let bytes = directorySize(entry)
            do {
                try fm.removeItem(at: entry)
                removed.append(Removed(name: entry.lastPathComponent, bytes: bytes))
            } catch { continue }   // best-effort: a locked/undeletable dir is skipped
        }
        return removed
    }

    /// The YYYY-MM-DD session date embedded in a relay dir name, or nil.
    /// Takes the LAST date-shaped token (target names may contain digits/hyphens)
    /// and requires it to be a real calendar date.
    static func sessionDate(fromName name: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.matches(in: name, range: range).last,
              let r = Range(match.range, in: name) else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = Calendar.current
        df.timeZone = Calendar.current.timeZone
        df.isLenient = false
        return df.date(from: String(name[r]))
    }

    /// Recursive allocated size (for the log line); best-effort.
    private static func directorySize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}
