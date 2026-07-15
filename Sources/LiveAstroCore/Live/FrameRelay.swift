import Foundation

/// Watches a source folder and stage-copies new matching files into a
/// local destination, so the native watcher never reads a partial file off a slow source.
/// Mirrors the proven seestar_relay.sh: mktemp stage → cp source→stage →
/// cp stage→dest, skip files already in dest.
public final class FrameRelay {
    private let source: URL
    private let destination: URL
    private let glob: String
    private let pollSeconds: Double
    /// Short within-tick re-stat interval used to detect a source file that is being
    /// actively written RIGHT NOW (size/mtime changes across the interval). Small so a
    /// static file relays on its first tick without a perceptible delay.
    private let stabilityInterval: Double
    public var onLog: ((String) -> Void)?
    public private(set) var relayedCount = 0
    private let sessionScoped: Bool
    private var baseline: Set<String> = []
    /// Per-file stat seen on the PREVIOUS poll tick. A file that changed between ticks
    /// (slow SMB writer appending across polls) is not yet stable — defer it. Keyed by name.
    private var lastSeen: [String: (size: Int, mtime: TimeInterval)] = [:]

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "frame.relay")

    public init(source: URL, destination: URL,
                glob: String = "Light_*_10.0s_*.fit", pollSeconds: Double = 5,
                sessionScoped: Bool = true, stabilityInterval: Double = 0.05) {
        self.source = source; self.destination = destination
        self.glob = glob; self.pollSeconds = pollSeconds
        self.sessionScoped = sessionScoped
        self.stabilityInterval = stabilityInterval
    }

    /// (size, mtime) for a source file, or nil if it can't be stat'd.
    private func stat(_ url: URL) -> (size: Int, mtime: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        queue.async { [weak self] in self?.snapshotBaseline() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollSeconds)
        t.setEventHandler { [weak self] in _ = try? self?.copyOnce() }
        timer = t; t.resume()
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// Snapshot the names already present in `source` (matching `glob`) so a
    /// session-scoped relay copies ONLY frames that appear afterward. No-op when
    /// `sessionScoped` is false. Source-unreachable → log + empty baseline
    /// (fail-open: relay rather than silently drop a whole session).
    func snapshotBaseline() {
        guard sessionScoped else { return }
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: source.path) }
        catch { onLog?("source unreachable (baseline): \(source.path)"); baseline = []; return }
        baseline = Set(names.filter { Self.wildcardMatch($0, glob) })
    }

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
        var seenThisTick: [String: (size: Int, mtime: TimeInterval)] = [:]
        for name in names.sorted() where Self.wildcardMatch(name, glob) {
            if baseline.contains(name) { continue }
            let dst = destination.appendingPathComponent(name)
            let src = source.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                // Presence-only skip would permanently block a truncated destination left by a
                // crash or pre-fix code. Compare sizes: if the destination already matches the
                // source (stable) size, it is fully relayed — skip as before. If it differs,
                // fall through so the staged-copy + atomic-rename path heals it.
                if let srcStat = stat(src), let dstAttrs = try? fm.attributesOfItem(atPath: dst.path),
                   let dstSize = (dstAttrs[.size] as? NSNumber)?.intValue, dstSize == srcStat.size {
                    continue   // sizes match → already fully relayed
                }
                // Size mismatch: treat as not-yet-relayed so it goes through the stability gate
                // and staged-copy path below, which will atomically replace the truncated copy.
            }

            guard let now = stat(src) else { continue }   // vanished between listing and stat
            seenThisTick[name] = now

            // Stability gate (spec P1-1). A slow SMB writer grows the file across poll ticks;
            // copying on first sighting yields a permanently truncated relay copy. So a file is
            // copied only once it is confirmed STABLE, detected two ways:
            //  (1) cross-tick: its (size, mtime) matches the stat recorded on the PREVIOUS tick.
            //      First sighting has no previous record → defer to the next tick.
            //  (2) within-tick: a short re-stat after `stabilityInterval` still matches — guards
            //      against a write that is in flight right now (mtime unchanged but size moving).
            guard let prev = lastSeen[name], prev == now else {
                onLog?("not yet stable, deferring: \(name)")
                continue   // first sighting or changed since last tick → not stable yet
            }
            Thread.sleep(forTimeInterval: stabilityInterval)
            guard let after = stat(src), after == now else {
                onLog?("actively writing, deferring: \(name)")
                continue   // changed during the interval → still being written
            }

            // Copy to a temp name in the DESTINATION dir, then atomically rename into place —
            // a downstream watcher never sees a partial destination file under its final name.
            let stg = stage.appendingPathComponent(name)
            let tmpDst = destination.appendingPathComponent(".\(name).relaytmp")
            do {
                try? fm.removeItem(at: tmpDst)
                try fm.copyItem(at: src, to: stg)      // slow SMB pull into stage (outside dest)
                try fm.copyItem(at: stg, to: tmpDst)   // fast local copy into dest (temp name)
                try? fm.removeItem(at: stg)
                // Re-stat the source: if it changed WHILE we were copying, the temp copy is
                // torn — discard it and retry on the next tick.
                guard let post = stat(src), post == now else {
                    try? fm.removeItem(at: tmpDst)
                    onLog?("changed during copy, retry next poll: \(name)")
                    continue
                }
                // Atomic placement: if dest already exists (truncated-heal path) replaceItemAt
                // atomically swaps it; otherwise moveItem renames into place. Both ensure the
                // watcher never observes a partial file under the final name.
                let healing = fm.fileExists(atPath: dst.path)
                if healing {
                    _ = try fm.replaceItemAt(dst, withItemAt: tmpDst, backupItemName: nil,
                                             options: .usingNewMetadataOnly)
                    onLog?("relay healed truncated \(name)")
                } else {
                    try fm.moveItem(at: tmpDst, to: dst)   // atomic rename into final name
                }
                copied += 1; relayedCount += 1
                onLog?("relayed: \(name) (\(relayedCount))")
            } catch {
                try? fm.removeItem(at: stg); try? fm.removeItem(at: tmpDst)  // retry next poll
                onLog?("retry next poll: \(name)")
            }
        }
        lastSeen = seenThisTick
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
