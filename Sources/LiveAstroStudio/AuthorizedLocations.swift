import Foundation

enum FileAccessPolicy: Sendable {
    case direct
    case sandboxed
}

struct BookmarkResolution: Sendable {
    let url: URL
    let isStale: Bool
}

protocol BookmarkAccessing: AnyObject, Sendable {
    func createBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> BookmarkResolution
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

final class FoundationBookmarkAccessor: BookmarkAccessing {
    func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope,
                             includingResourceValuesForKeys: nil,
                             relativeTo: nil)
    }

    func resolveBookmark(_ data: Data) throws -> BookmarkResolution {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return BookmarkResolution(url: url.standardizedFileURL, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

final class FileAccessLease: Sendable {
    let url: URL
    private let cleanup: (@Sendable () -> Void)?

    init(url: URL, cleanup: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.cleanup = cleanup
    }

    deinit {
        cleanup?()
    }
}

enum AuthorizedLocationError: Error, Equatable {
    case missingSelection(String)
    case notAuthorized(URL)
    case accessDenied(URL)
    case malformedStorage
    case unsupportedStorageVersion(Int)
}

extension AuthorizedLocationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .missingSelection(key):
            "No authorized location is saved for \(key)."
        case let .notAuthorized(url):
            "The location is not covered by a saved folder permission: \(url.path)"
        case let .accessDenied(url):
            "The saved folder permission is unavailable: \(url.path)"
        case .malformedStorage:
            "Saved folder permissions are malformed and were left unchanged."
        case let .unsupportedStorageVersion(version):
            "Saved folder permissions use unsupported version \(version) and were left unchanged."
        }
    }
}

@MainActor
final class AuthorizedLocations {
    enum Request { case key(String), url(URL) }
    static let defaultsKey = "AuthorizedLocations.records"

    private static let storageVersion = 1

    private struct Envelope: Codable {
        var version: Int
        var records: [String: Record]
    }

    private struct Record: Codable {
        var purpose: String
        var displayPath: String
        var bookmark: Data?
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private let defaults: UserDefaults
    private let policy: FileAccessPolicy
    private let containerRoots: [URL]
    private let backend: any BookmarkAccessing

    init(defaults: UserDefaults,
         policy: FileAccessPolicy,
         containerRoots: [URL],
         backend: any BookmarkAccessing = FoundationBookmarkAccessor()) {
        self.defaults = defaults
        self.policy = policy
        self.containerRoots = containerRoots.map(Self.normalize)
        self.backend = backend
    }

    func select(_ url: URL, key: String) throws -> FileAccessLease {
        var envelope = try loadEnvelope()
        let selectedURL = Self.normalize(url)

        switch policy {
        case .direct:
            envelope.records[key] = Record(purpose: key,
                                           displayPath: selectedURL.path,
                                           bookmark: nil)
            try persist(envelope)
            return FileAccessLease(url: selectedURL)

        case .sandboxed where isInContainer(selectedURL):
            envelope.records[key] = Record(purpose: key,
                                           displayPath: selectedURL.path,
                                           bookmark: nil)
            try persist(envelope)
            return FileAccessLease(url: selectedURL)

        case .sandboxed:
            let bookmark = try backend.createBookmark(for: selectedURL)
            let resolution = try backend.resolveBookmark(bookmark)
            let resolvedURL = Self.normalize(resolution.url)
            guard backend.startAccessing(resolvedURL) else {
                throw AuthorizedLocationError.accessDenied(resolvedURL)
            }

            do {
                let storedBookmark = resolution.isStale
                    ? try backend.createBookmark(for: resolvedURL)
                    : bookmark
                envelope.records[key] = Record(purpose: key,
                                               displayPath: resolvedURL.path,
                                               bookmark: storedBookmark)
                try persist(envelope)
            } catch {
                backend.stopAccessing(resolvedURL)
                throw error
            }

            return scopedLease(url: resolvedURL, scopeURL: resolvedURL)
        }
    }

    func acquire(key: String) throws -> FileAccessLease {
        var envelope = try loadEnvelope()
        return try acquire(key: key, record: envelope.records[key], envelope: &envelope)
    }

    /// Match every request against this call's original roots, while persisting
    /// renewals into one current envelope. The old matching roots never escape.
    /// Callers own all successful leases, including when other requests fail.
    func acquireGroup(_ requests: [Request]) -> [Result<FileAccessLease, Error>] {
        do {
            var envelope = try loadEnvelope()
            let original = envelope.records
            return requests.map { request in
                Result {
                    switch request {
                    case .key(let key): return try acquire(key: key, record: original[key], envelope: &envelope)
                    case .url(let url): return try acquire(url: Self.normalize(url), matching: original, envelope: &envelope)
                    }
                }
            }
        } catch {
            return requests.map { request in
                // Path-only direct/container access never depends on saved storage.
                if case .url(let url) = request, policy == .direct || isInContainer(url) {
                    return .success(FileAccessLease(url: Self.normalize(url)))
                }
                return .failure(error)
            }
        }
    }

    private func acquire(key: String, record: Record?, envelope: inout Envelope) throws -> FileAccessLease {
        guard let record else {
            throw AuthorizedLocationError.missingSelection(key)
        }
        let displayedURL = Self.fileURL(path: record.displayPath)

        if policy == .direct || isInContainer(displayedURL) {
            return FileAccessLease(url: displayedURL)
        }

        guard let bookmark = record.bookmark else {
            throw AuthorizedLocationError.notAuthorized(displayedURL)
        }
        let resolution = try backend.resolveBookmark(bookmark)
        let resolvedURL = Self.normalize(resolution.url)
        guard backend.startAccessing(resolvedURL) else {
            throw AuthorizedLocationError.accessDenied(resolvedURL)
        }

        renewIfStale(resolution,
                     key: key,
                     purpose: record.purpose,
                     envelope: &envelope)
        return scopedLease(url: resolvedURL, scopeURL: resolvedURL)
    }

    func acquire(url: URL) throws -> FileAccessLease {
        let requestedURL = Self.normalize(url)
        if policy == .direct || isInContainer(requestedURL) {
            return FileAccessLease(url: requestedURL)
        }

        var envelope = try loadEnvelope()
        let original = envelope.records
        return try acquire(url: requestedURL, matching: original, envelope: &envelope)
    }

    private func acquire(url requestedURL: URL, matching records: [String: Record],
                         envelope: inout Envelope) throws -> FileAccessLease {
        if policy == .direct || isInContainer(requestedURL) { return FileAccessLease(url: requestedURL) }
        let candidates = records.sorted {
            Self.fileURL(path: $0.value.displayPath).pathComponents.count
                > Self.fileURL(path: $1.value.displayPath).pathComponents.count
        }
        var matchingError: (any Error)?

        for (key, record) in candidates {
            guard let bookmark = record.bookmark else { continue }
            let displayedRoot = Self.fileURL(path: record.displayPath)
            let displayedSuffix = Self.relativeComponents(of: requestedURL, under: displayedRoot)
            let resolution: BookmarkResolution
            do {
                resolution = try backend.resolveBookmark(bookmark)
            } catch {
                if displayedSuffix != nil, matchingError == nil {
                    matchingError = error
                }
                continue
            }

            let resolvedRoot = Self.normalize(resolution.url)
            let operationURL: URL
            if let displayedSuffix {
                operationURL = displayedSuffix.reduce(resolvedRoot) {
                    $0.appendingPathComponent($1)
                }.standardizedFileURL
            } else if Self.relativeComponents(of: requestedURL, under: resolvedRoot) != nil {
                operationURL = requestedURL
            } else {
                continue
            }

            guard backend.startAccessing(resolvedRoot) else {
                if matchingError == nil {
                    matchingError = AuthorizedLocationError.accessDenied(resolvedRoot)
                }
                continue
            }

            renewIfStale(resolution,
                         key: key,
                         purpose: record.purpose,
                         envelope: &envelope)
            return scopedLease(url: operationURL, scopeURL: resolvedRoot)
        }

        if let matchingError {
            throw matchingError
        }
        throw AuthorizedLocationError.notAuthorized(requestedURL)
    }

    func displayURL(key: String) -> URL? {
        guard let envelope = try? loadEnvelope(),
              let record = envelope.records[key] else {
            return nil
        }
        return Self.fileURL(path: record.displayPath)
    }

    private func loadEnvelope() throws -> Envelope {
        guard defaults.object(forKey: Self.defaultsKey) != nil else {
            return Envelope(version: Self.storageVersion, records: [:])
        }
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            throw AuthorizedLocationError.malformedStorage
        }

        let decoder = JSONDecoder()
        let header: VersionHeader
        do {
            header = try decoder.decode(VersionHeader.self, from: data)
        } catch {
            throw AuthorizedLocationError.malformedStorage
        }
        guard header.version == Self.storageVersion else {
            throw AuthorizedLocationError.unsupportedStorageVersion(header.version)
        }
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.records.allSatisfy({ key, record in
                record.purpose == key && record.displayPath.hasPrefix("/")
            }) else {
                throw AuthorizedLocationError.malformedStorage
            }
            return envelope
        } catch let error as AuthorizedLocationError {
            throw error
        } catch {
            throw AuthorizedLocationError.malformedStorage
        }
    }

    private func persist(_ envelope: Envelope) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(envelope), forKey: Self.defaultsKey)
    }

    private func renewIfStale(_ resolution: BookmarkResolution,
                              key: String,
                              purpose: String,
                              envelope: inout Envelope) {
        guard resolution.isStale else { return }
        let resolvedURL = Self.normalize(resolution.url)
        do {
            let renewedBookmark = try backend.createBookmark(for: resolvedURL)
            envelope.records[key] = Record(purpose: purpose,
                                           displayPath: resolvedURL.path,
                                           bookmark: renewedBookmark)
            try persist(envelope)
        } catch {
            // Current access remains valid. Keep the prior record if best-effort
            // renewal fails, rather than destroying the user's saved selection.
        }
    }

    private func scopedLease(url: URL, scopeURL: URL) -> FileAccessLease {
        FileAccessLease(url: url) { [backend] in
            backend.stopAccessing(scopeURL)
        }
    }

    private func isInContainer(_ url: URL) -> Bool {
        let canonicalURL = Self.canonicalForContainment(url)
        return containerRoots.contains {
            Self.relativeComponents(of: canonicalURL,
                                    under: Self.canonicalForContainment($0)) != nil
        }
    }

    private static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    private static func canonicalForContainment(_ url: URL) -> URL {
        var existingAncestor = normalize(url)
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != "/" {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }
        return missingComponents.reduce(existingAncestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }

    private static func fileURL(path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func relativeComponents(of child: URL, under parent: URL) -> ArraySlice<String>? {
        let child = normalize(child)
        let parent = normalize(parent)
        guard child.isFileURL,
              parent.isFileURL,
              child.host == parent.host else {
            return nil
        }
        let childComponents = child.pathComponents
        let parentComponents = parent.pathComponents
        guard childComponents.count >= parentComponents.count,
              Array(childComponents.prefix(parentComponents.count)) == parentComponents else {
            return nil
        }
        return childComponents.dropFirst(parentComponents.count)
    }
}
