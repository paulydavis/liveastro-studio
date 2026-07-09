import Foundation

/// Watches a Seestar `_sub` folder and stage-copies new matching subs into a
/// local destination, so the native watcher never reads a partial FITS off SMB.
/// Mirrors the proven seestar_relay.sh: mktemp stage → cp source→stage →
/// cp stage→dest, skip files already in dest.
public final class SeestarRelay {
    private let source: URL
    private let destination: URL
    private let glob: String
    private let pollSeconds: Double
    public var onLog: ((String) -> Void)?
    public private(set) var relayedCount = 0

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "seestar.relay")

    public init(source: URL, destination: URL,
                glob: String = "Light_*_10.0s_*.fit", pollSeconds: Double = 5) {
        self.source = source; self.destination = destination
        self.glob = glob; self.pollSeconds = pollSeconds
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollSeconds)
        t.setEventHandler { [weak self] in _ = try? self?.copyOnce() }
        timer = t; t.resume()
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// One relay pass: copy new matching files not yet in destination. Returns count copied.
    @discardableResult
    func copyOnce() throws -> Int {
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: source.path) }
        catch { onLog?("source unreachable: \(source.path)"); return 0 }
        let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                               appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: stage) }
        var copied = 0
        for name in names.sorted() where Self.wildcardMatch(name, glob) {
            let dst = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            let src = source.appendingPathComponent(name)
            let stg = stage.appendingPathComponent(name)
            do {
                try fm.copyItem(at: src, to: stg)      // slow SMB pull into stage (outside dest)
                try fm.copyItem(at: stg, to: dst)      // fast local copy into dest (atomic enough)
                try? fm.removeItem(at: stg)
                copied += 1; relayedCount += 1
                onLog?("relayed: \(name) (\(relayedCount))")
            } catch {
                try? fm.removeItem(at: stg); try? fm.removeItem(at: dst)  // retry next poll
                onLog?("retry next poll: \(name)")
            }
        }
        return copied
    }

    /// Minimal `*` wildcard match (no `?`), case-sensitive. Two-pointer with backtracking.
    static func wildcardMatch(_ name: String, _ pattern: String) -> Bool {
        let s = Array(name), p = Array(pattern)
        var si = 0, pi = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count && (p[pi] == s[si]) { si += 1; pi += 1 }
            else if pi < p.count && p[pi] == "*" { star = pi; mark = si; pi += 1 }
            else if star != -1 { pi = star + 1; mark += 1; si = mark }
            else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
