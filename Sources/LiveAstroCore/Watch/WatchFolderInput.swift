import Foundation

/// What a session is about to consume, decided BEFORE it starts.
///
/// A live session used to be silent about its input: subs already sitting in the watch folder
/// were stacked without a word, and a filename filter matching nothing looked exactly like
/// "capture hasn't started yet". This type is the single source of both answers — and it uses
/// the WATCHER's acceptance rule, so the count an operator is shown is the count that will
/// actually be stacked.
public enum WatchFolderInput {

    /// The one "is this a sub" rule. `StackFileWatcher` calls this; so does `snapshot(folder:)`.
    /// Dotfiles and `.tmp` are excluded because a rig writes its subs through both while a
    /// capture is still in flight — counting them would over-report what the session receives.
    public static func isTrackedFileName(_ name: String, fileNamePrefix: String?) -> Bool {
        guard !name.hasPrefix("."), !name.lowercased().hasSuffix(".tmp") else { return false }
        if let prefix = fileNamePrefix, !prefix.isEmpty,
           !name.lowercased().hasPrefix(prefix.lowercased()) { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ImageLoader.fitsExtensions.contains(ext)
            || ImageLoader.bitmapExtensions.contains(ext)
    }

    /// Why a folder could not be read. Distinct from an empty result ON PURPOSE: telling an
    /// operator "no matching subs found, waiting for new files" when the folder cannot be read
    /// at all would have them waiting for files that can never arrive.
    public struct SnapshotFailure: LocalizedError, CustomStringConvertible, Equatable {
        public let folder: URL
        public let reason: String
        public var description: String { "cannot read \(folder.path): \(reason)" }
        public var errorDescription: String? { description }
    }

    /// The set of subs present at a single instant, bound to the folder and filter it was
    /// taken for. Everything NOT in here is new — including anything that lands while the
    /// operator is still answering the confirmation.
    public struct Snapshot: Sendable, Equatable {
        public let folder: URL
        public let fileNamePrefix: String?
        /// name → identity at snapshot time. The app adds a content baseline off-main
        /// before asking about exclusion; stat-only snapshots remain usable by older callers.
        public let existing: [String: FileIdentity]
        /// Files present that the filter rejected. Non-zero with an empty `existing` is the
        /// prefix-typo tell — "23 files present, none match `Light_`".
        public let unmatchedFileCount: Int

        public var isEmpty: Bool { existing.isEmpty }
        public var count: Int { existing.count }

        /// Content baseline work runs off the main actor; callers may cancel between chunks.
        public func addingContentBaseline(shouldCancel: @escaping () -> Bool = { false },
                                          progress: (Int, Int) -> Void = { _, _ in }) throws -> Snapshot {
            var recorded: [String: FileIdentity] = [:]
            progress(0, count)
            for name in existing.keys.sorted() {
                if shouldCancel() { throw CancellationError() }
                let url = folder.appendingPathComponent(name)
                guard let expected = existing[name],
                      let handle = try? FileHandle(forReadingFrom: url) else {
                    throw SnapshotFailure(folder: folder, reason: "cannot read \(name) for input baseline")
                }
                defer { try? handle.close() }
                var before = Darwin.stat(), after = Darwin.stat()
                guard fstat(handle.fileDescriptor, &before) == 0, expected.matches(stat: before) else {
                    throw SnapshotFailure(folder: folder, reason: "\(name) changed while preparing input baseline; retry Start")
                }
                let digest = FileIdentity.contentDigest(handle: handle, size: expected.size, shouldAbort: shouldCancel)
                if shouldCancel() { throw CancellationError() }
                guard let digest, fstat(handle.fileDescriptor, &after) == 0, expected.matches(stat: after),
                      let current = FileIdentity.capture(url: url), recordedUnchanged(name: name, identity: current) else {
                    throw SnapshotFailure(folder: folder, reason: "could not establish a stable input baseline for \(name); retry Start")
                }
                recorded[name] = expected.withDigest(digest)
                progress(recorded.count, count)
            }
            if shouldCancel() { throw CancellationError() }
            return Snapshot(folder: folder, fileNamePrefix: fileNamePrefix, existing: recorded,
                            unmatchedFileCount: unmatchedFileCount)
        }

        /// True when this snapshot still describes the given selection. The confirmation is
        /// answered later; if the operator changed folder or filter meanwhile, this snapshot
        /// describes something else and must not be used to exclude anything.
        public func covers(folder: URL, fileNamePrefix: String?) -> Bool {
            let mine = (fileNamePrefix?.isEmpty ?? true) ? nil : fileNamePrefix
            let theirs = (self.fileNamePrefix?.isEmpty ?? true) ? nil : self.fileNamePrefix
            return self.folder.standardizedFileURL == folder.standardizedFileURL && mine == theirs
        }

        /// True for the same stat version, or matching content despite identity churn.
        ///
        /// The cheap path compares dev/ino/size/mtime. If they differ, both full digests
        /// must agree, as well as the size. Growing files and changed bytes are new input.
        /// A write that preserves ALL stat fields remains invisible to the cheap path;
        /// this is the same immutable-after-publication assumption as the native watcher.
        /// Missing identity/digest is never guessed equal.
        public func recordedUnchanged(name: String, identity: FileIdentity?) -> Bool {
            guard let recorded = existing[name], let identity else { return false }
            let sameStat = recorded.dev == identity.dev && recorded.ino == identity.ino
                && recorded.size == identity.size
                && recorded.mtimeSec == identity.mtimeSec
                && recorded.mtimeNsec == identity.mtimeNsec
            if sameStat { return true }
            // A zero-length file has exactly one possible byte sequence. No read is
            // needed to certify its identity churn against a verified empty baseline.
            if recorded.size == 0, identity.size == 0,
               recorded.digest == FileIdentity.contentDigest(data: Data()) { return true }
            // Same name and size alone are never evidence of equality. Only a baseline
            // digest captured from the old version can certify identity churn.
            guard recorded.size == identity.size, let baseline = recorded.digest,
                  let observed = identity.digest else { return false }
            return baseline == observed
        }
    }

    /// Lists `folder` once and records every sub the watcher would accept.
    ///
    /// Throws `SnapshotFailure` when the folder cannot be listed, or when a matching file
    /// cannot be stat'd for any reason other than having vanished. A vanished file is simply
    /// not present and is dropped from the snapshot — which, if it reappears, makes it new.
    public static func snapshot(folder: URL, fileNamePrefix: String?) throws -> Snapshot {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw SnapshotFailure(folder: folder, reason: error.localizedDescription)
        }

        var existing: [String: FileIdentity] = [:]
        var unmatched = 0
        for name in names {
            var st = Darwin.stat()
            let statted = lstat(folder.appendingPathComponent(name).path, &st) == 0
            if !statted {
                // Vanished between listing and stat: genuinely not present. Anything else is
                // a real read failure and must not be smuggled into a count.
                if errno == ENOENT { continue }
                throw SnapshotFailure(folder: folder,
                                      reason: "cannot stat \(name): \(String(cString: strerror(errno)))")
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else { continue }   // directories are not input
            if isTrackedFileName(name, fileNamePrefix: fileNamePrefix) {
                existing[name] = FileIdentity(stat: st)
            } else {
                unmatched += 1
            }
        }
        return Snapshot(folder: folder, fileNamePrefix: fileNamePrefix,
                        existing: existing, unmatchedFileCount: unmatched)
    }
}
