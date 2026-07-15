import Foundation

/// Per-test filesystem sandbox on the SAME volume as the test process (spec engineering rule:
/// "temp directories on the same filesystem as the test process; teardown always succeeds").
///
/// Every permission change made through this sandbox is tracked so `tearDown()` can restore the
/// original mode before removal — a read-only subdir left in place would make removal fail, which
/// would poison later tests. Teardown is therefore unconditional and never throws.
final class TempFS {
    let root: URL
    /// Original POSIX permission bits per path, captured the first time a path is flipped.
    private var originalPermissions: [String: NSNumber] = [:]

    init(_ name: String) throws {
        // FileManager.temporaryDirectory is on the test process's volume — same filesystem,
        // so master/master.fit copies and renames behave like production.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faultkit-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Create (if needed) and return a subdirectory at `rel` under the root.
    func dir(_ rel: String) throws -> URL {
        let url = root.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Remember `url`'s current permission bits so teardown can restore them before removal.
    /// Idempotent: the FIRST recorded value wins, so repeated flips still restore the real original.
    func trackPermissionChange(at url: URL) {
        guard originalPermissions[url.path] == nil else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        // Default to 0o755 if the attribute is somehow unreadable — restores a removable mode.
        originalPermissions[url.path] = (attrs?[.posixPermissions] as? NSNumber) ?? NSNumber(value: 0o755)
    }

    /// Restore every tracked permission, then remove the root. NEVER throws: a failure to restore
    /// or remove must not turn into a test error that masks the real assertion.
    func tearDown() {
        for (path, perm) in originalPermissions {
            try? FileManager.default.setAttributes([.posixPermissions: perm], ofItemAtPath: path)
        }
        // Restore the root itself too, in case a child flip cascaded (defensive).
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                               ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
        originalPermissions.removeAll()
    }
}
