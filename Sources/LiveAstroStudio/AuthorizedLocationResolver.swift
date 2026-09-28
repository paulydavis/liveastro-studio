import Foundation
import Darwin

/// Filesystem and security-scope work only. No UI or preference-store ownership.
struct AuthorizedLocationResolver {
    typealias Store = AuthorizedLocations
    let input: Store.ResolutionInput
    private var changes: [String: Store.GrantChange] = [:]
    private var relocations: [String: Store.Relocation] = [:]

    init(_ input: Store.ResolutionInput) { self.input = input }

    mutating func resolve() -> Store.PreparedAccess {
        let results = input.requests.map { request in
            Result<FileAccessLease, Error> {
                try Task.checkCancellation()
                switch request {
                case .key(let key):
                    if let error = input.storageError { throw error }
                    guard let record = input.records[key] else { throw AuthorizedLocationError.missingSelection(key) }
                    let url = URL(fileURLWithPath: record.displayPath, isDirectory: true).standardizedFileURL
                    if try isUnscoped(url) { return try unscoped(url) }
                    return try resolveRecord(key, record: record, requested: nil)
                case .url(let url):
                    let url = url.standardizedFileURL
                    if try isUnscoped(url) { return try unscoped(url) }
                    if let error = input.storageError { throw error }
                    var matchingError: Error?
                    let byDepth = input.records.sorted {
                        URL(fileURLWithPath: $0.value.displayPath).pathComponents.count > URL(fileURLWithPath: $1.value.displayPath).pathComponents.count
                    }
                    func covers(_ record: Store.Record) -> Bool {
                        Self.suffix(url, under: URL(fileURLWithPath: record.displayPath)) != nil
                    }
                    // Resolve unrelated bookmarks only as a moved-root fallback.
                    // A disconnected share must not delay a healthy covering grant.
                    let candidates = byDepth.filter { covers($0.value) } + byDepth.filter { !covers($0.value) }
                    for (key, record) in candidates where record.bookmark != nil {
                        do { return try resolveRecord(key, record: record, requested: url) }
                        catch is UnrelatedGrant { continue }
                        catch {
                            if error is CancellationError { throw error }
                            if Self.suffix(url, under: URL(fileURLWithPath: record.displayPath)) != nil, matchingError == nil { matchingError = error }
                        }
                    }
                    throw matchingError ?? AuthorizedLocationError.notAuthorized(url)
                }
            }
        }
        return Store.PreparedAccess(results: results, relocations: Array(relocations.values), changes: Array(changes.values))
    }

    mutating func select(_ url: URL, key: String) throws -> Store.PreparedAccess {
        try Task.checkCancellation()
        if let error = input.storageError { throw error }
        let url = url.standardizedFileURL
        let record: Store.Record
        let lease: FileAccessLease
        if try isUnscoped(url) {
            record = Store.Record(purpose: key, displayPath: url.path, bookmark: nil)
            lease = try unscoped(url)
        } else {
            let bookmark = try input.backend.createBookmark(for: url)
            try Task.checkCancellation()
            let resolution = try input.backend.resolveBookmark(bookmark)
            let resolved = resolution.url.standardizedFileURL
            try Task.checkCancellation()
            guard input.backend.startAccessing(resolved) else { throw AuthorizedLocationError.accessDenied(resolved) }
            lease = try scoped(resolved, root: resolved)
            let data = resolution.isStale ? try input.backend.createBookmark(for: resolved) : bookmark
            try Task.checkCancellation()
            record = Store.Record(purpose: key, displayPath: resolved.path, bookmark: data)
        }
        return Store.PreparedAccess(results: [.success(lease)], relocations: [],
                                    changes: [.init(key: key, original: input.records[key], replacement: record)])
    }

    private struct UnrelatedGrant: Error {}

    private mutating func resolveRecord(_ key: String, record: Store.Record, requested: URL?) throws -> FileAccessLease {
        guard let bookmark = record.bookmark else { throw AuthorizedLocationError.notAuthorized(URL(fileURLWithPath: record.displayPath)) }
        let resolution = try input.backend.resolveBookmark(bookmark)
        try Task.checkCancellation()
        let root = resolution.url.standardizedFileURL
        let oldRoot = URL(fileURLWithPath: record.displayPath).standardizedFileURL
        let url: URL
        if let requested {
            if let suffix = Self.suffix(requested, under: oldRoot) {
                url = suffix.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
            } else if Self.suffix(requested, under: root) != nil { url = requested }
            else { throw UnrelatedGrant() }
        } else { url = root }
        guard input.backend.startAccessing(root) else { throw AuthorizedLocationError.accessDenied(root) }
        let lease = try scoped(url, root: root)
        if oldRoot.path != root.path {
            relocations[key] = .init(key: key, original: record, oldRoot: oldRoot, newRoot: root)
        }
        if resolution.isStale {
            // Renewal is best effort, while the acquired lease remains valid.
            if let data = try? input.backend.createBookmark(for: root) {
                changes[key] = .init(key: key, original: record,
                                     replacement: .init(purpose: record.purpose, displayPath: root.path, bookmark: data))
            }
        }
        try Task.checkCancellation()
        return lease
    }

    private func unscoped(_ url: URL) throws -> FileAccessLease {
        FileAccessLease(url: url, canonicalURL: try input.canonicalizer.canonicalURL(url))
    }

    private func scoped(_ url: URL, root: URL) throws -> FileAccessLease {
        let owner = FileAccessLease(url: root) { [backend = input.backend] in backend.stopAccessing(root) }
        return FileAccessLease(url: url, canonicalURL: try input.canonicalizer.canonicalURL(url)) {
            withExtendedLifetime(owner) {}
        }
    }

    private func isUnscoped(_ url: URL) throws -> Bool {
        if input.policy == .direct { return true }
        try Task.checkCancellation()
        guard let canonical = try? input.canonicalizer.canonicalURL(url) else { return false }
        for root in input.containerRoots {
            try Task.checkCancellation()
            if let canonicalRoot = try? input.canonicalizer.canonicalURL(root),
               Self.suffix(canonical, under: canonicalRoot) != nil { return true }
        }
        return false
    }

    static func suffix(_ child: URL, under parent: URL) -> ArraySlice<String>? {
        let child = child.standardizedFileURL, parent = parent.standardizedFileURL
        guard child.isFileURL, parent.isFileURL, child.host == parent.host else { return nil }
        let c = child.pathComponents, p = parent.pathComponents
        guard c.count >= p.count, Array(c.prefix(p.count)) == p else { return nil }
        return c.dropFirst(p.count)
    }
}

protocol LocationCanonicalizing: Sendable {
    func canonicalURL(_ url: URL) throws -> URL
}

struct FileLocationCanonicalizer: LocationCanonicalizing {
    func canonicalURL(_ url: URL) throws -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            var metadata = stat()
            if lstat(ancestor.path, &metadata) == 0 {
                // fileExists follows links. A link whose target is unavailable
                // is not a missing child that can safely inherit containment.
                throw AuthorizedLocationError.accessDenied(ancestor)
            }
            guard errno == ENOENT else { throw AuthorizedLocationError.accessDenied(ancestor) }
            missing.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        return missing.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL
    }
}
