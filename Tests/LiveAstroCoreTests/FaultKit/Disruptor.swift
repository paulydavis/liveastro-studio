import Foundation

/// Applies a named disruption at a coordinated point in a fault test. All operations act on the
/// REAL filesystem (spec: "exercise real filesystem behavior by default"). Chmod-based disruptions
/// are PROXIES for disk-full/EIO and first probe their own effectiveness, because a privileged
/// runner can defeat chmod — the caller must XCTSkip rather than pass vacuously.
enum Disruptor {
    static func deleteFile(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Truncate an existing file to `bytes` (models a partial/corrupt durable file).
    static func truncateFile(_ url: URL, to bytes: Int) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: UInt64(bytes))
        try h.synchronize()
    }

    static func removeDirectory(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Flip `url` read-only (mode 0o555) as a proxy for a read-only / ENOSPC destination.
    /// Returns `true` if the change is EFFECTIVE for this process — verified with a write-probe.
    /// Returns `false` (so the caller XCTSkips with a diagnostic) when a privileged runner can
    /// still write despite the chmod. The permission change is tracked on `tempFS` for restore.
    @discardableResult
    static func makeReadOnly(_ url: URL, tempFS: TempFS) throws -> Bool {
        tempFS.trackPermissionChange(at: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)],
                                              ofItemAtPath: url.path)
        return probeReadOnlyEffective(url)
    }

    /// Write-probe: attempt to create a file inside a directory (or open a file for writing).
    /// If the write SUCCEEDS despite the read-only flip, chmod is ineffective (privileged) → false.
    private static func probeReadOnlyEffective(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let probe = url.appendingPathComponent(".faultkit-write-probe-\(UUID().uuidString)")
            let wrote = (try? Data("x".utf8).write(to: probe)) != nil
            if wrote { try? FileManager.default.removeItem(at: probe) }
            return !wrote   // effective iff the write FAILED
        } else {
            // Regular file: opening for writing must fail when chmod is effective.
            if let h = try? FileHandle(forWritingTo: url) { try? h.close(); return false }
            return true
        }
    }

    /// Replace a file path with a DIRECTORY at the same path — an invalid replacement target
    /// (writers expecting a file will fail). Removes the original first.
    static func replaceWithDirectory(_ fileURL: URL) throws {
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    }

    /// Atomically SWAP the directory at `target` with the directory at `replacement` in a single
    /// `renamex_np(RENAME_SWAP)` syscall — the target path NEVER has a missing interval
    /// (`fileExists` never reports false), but after the call it is a DIFFERENT inode.
    /// Models a writer that rebuilds its output directory aside and rename()s it into place.
    static func atomicallySwapDirectory(at target: URL, with replacement: URL) throws {
        guard renamex_np(replacement.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                                     "renamex_np(RENAME_SWAP) \(replacement.path) <-> \(target.path)"])
        }
    }

    /// Replace a path with a symlink pointing at a non-existent target (dangling symlink) —
    /// stat/open of the final path fails with ENOENT while the link entry itself exists.
    static func replaceWithDanglingSymlink(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }
}
