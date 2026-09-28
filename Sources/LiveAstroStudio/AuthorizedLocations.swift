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
    /// Captured off-main while access is held; never re-resolve a retained
    /// session's old root after the operator has selected a different one.
    let canonicalURL: URL
    private let cleanup: (@Sendable () -> Void)?

    init(url: URL, canonicalURL: URL? = nil, cleanup: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.canonicalURL = canonicalURL ?? url.standardizedFileURL
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
    enum Request: Sendable { case key(String), url(URL) }
    static let defaultsKey = "AuthorizedLocations.records"

    private static let storageVersion = 1

    private struct Envelope: Codable {
        var version: Int
        var records: [String: Record]
    }

    struct Record: Codable, Equatable, Sendable {
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
    private let canonicalizer: any LocationCanonicalizing
    private var selectionGenerations: [String: UUID] = [:]

    struct ResolutionInput: Sendable {
        let requests: [Request]
        let records: [String: Record]
        let policy: FileAccessPolicy
        let containerRoots: [URL]
        let backend: any BookmarkAccessing
        let canonicalizer: any LocationCanonicalizing
        let storageError: AuthorizedLocationError?
    }
    struct GrantChange: Sendable {
        let key: String
        let original: Record?
        let replacement: Record
        var selectionID: UUID? = nil
    }
    struct Relocation: Sendable {
        let key: String
        let original: Record
        let oldRoot: URL
        let newRoot: URL
    }
    struct PreparedAccess: Sendable {
        let results: [Result<FileAccessLease, Error>]
        let relocations: [Relocation]
        let changes: [GrantChange]
    }

    init(defaults: UserDefaults,
         policy: FileAccessPolicy,
         containerRoots: [URL],
         backend: any BookmarkAccessing = FoundationBookmarkAccessor(),
         canonicalizer: any LocationCanonicalizing = FileLocationCanonicalizer()) {
        self.defaults = defaults
        self.policy = policy
        self.containerRoots = containerRoots.map(Self.normalize)
        self.backend = backend
        self.canonicalizer = canonicalizer
    }

    func snapshot(_ requests: [Request]) -> ResolutionInput {
        let records: [String: Record]
        let storageFailure: AuthorizedLocationError?
        do { records = try loadEnvelope().records; storageFailure = nil }
        catch let failure as AuthorizedLocationError { records = [:]; storageFailure = failure }
        catch { records = [:]; storageFailure = .malformedStorage }
        return ResolutionInput(requests: requests, records: records, policy: policy,
                               containerRoots: containerRoots, backend: backend,
                               canonicalizer: canonicalizer, storageError: storageFailure)
    }

    func prepare(_ requests: [Request]) async throws -> PreparedAccess {
        let input = snapshot(requests)
        let worker = Task.detached(priority: .userInitiated) {
            var resolver = AuthorizedLocationResolver(input)
            return resolver.resolve()
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    func prepareSelection(_ url: URL, key: String) async throws -> PreparedAccess {
        let id = UUID()
        selectionGenerations[key] = id
        let input = snapshot([])
        let worker = Task.detached(priority: .userInitiated) {
            var resolver = AuthorizedLocationResolver(input)
            return try resolver.select(url, key: key)
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard selectionGenerations[key] == id else { throw CancellationError() }
        return PreparedAccess(results: result.results, relocations: result.relocations,
                              changes: result.changes.map { change in
            var change = change
            change.selectionID = id
            return change
        })
    }

    func matches(_ relocation: Relocation) -> Bool {
        (try? loadEnvelope().records[relocation.key]) == relocation.original
    }

    func commit(_ changes: [GrantChange]) throws {
        guard !changes.isEmpty else { return }
        var envelope = try loadEnvelope()
        for change in changes {
            if let id = change.selectionID {
                // A still-current operator choice wins over an intervening
                // background renewal, but never over a newer explicit choice.
                guard selectionGenerations[change.key] == id else { throw CancellationError() }
                envelope.records[change.key] = change.replacement
            } else if envelope.records[change.key] == change.original {
                envelope.records[change.key] = change.replacement
            }
        }
        try persist(envelope)
    }

    func select(_ url: URL, key: String) async throws -> FileAccessLease {
        let prepared = try await prepareSelection(url, key: key)
        try commit(prepared.changes)
        return try prepared.results[0].get()
    }
    func acquire(key: String) async throws -> FileAccessLease {
        let prepared = try await prepare([.key(key)])
        try commit(prepared.changes)
        return try prepared.results[0].get()
    }
    func acquire(url: URL) async throws -> FileAccessLease {
        let prepared = try await prepare([.url(url)])
        try commit(prepared.changes)
        return try prepared.results[0].get()
    }
    func acquireGroup(_ requests: [Request]) async -> [Result<FileAccessLease, Error>] {
        do {
            let prepared = try await prepare(requests)
            try commit(prepared.changes)
            return prepared.results
        } catch { return requests.map { _ in .failure(error) } }
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

    private static func normalize(_ url: URL) -> URL { url.standardizedFileURL }
    private static func fileURL(path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
}
