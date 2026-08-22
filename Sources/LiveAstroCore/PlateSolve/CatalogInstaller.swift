import Foundation
import CryptoKit

/// Downloads the Gaia bright-star catalog (~32 MB) on demand and caches it locally, so plate-solving
/// works in the shipped app WITHOUT bundling the CC BY-NC Gaia data (sub-project 3c).
///
/// Integrity is enforced: the download is verified against `expectedSHA256` (which is REQUIRED — an
/// empty value fails closed rather than silently accepting an unverified file) AND must parse as a
/// non-empty catalog, and it's written atomically. So the cache only ever holds a complete, verified
/// catalog — never a partial one, and never a wrong-but-parseable one.
public enum CatalogInstaller {
    /// GitHub Release asset URL for the pre-built G<=11 catalog. PLACEHOLDER until the asset is uploaded
    /// (see docs/CATALOG.md).
    public static var remoteURL = URL(string: "https://github.com/paulydavis/liveastro-studio/releases/download/catalog-v1/brightstars.bin")!
    /// Lowercase hex SHA-256 of the release asset (see docs/CATALOG.md). REQUIRED: an empty value makes
    /// `download` throw `.checksumNotConfigured` rather than install an unverified file.
    public static var expectedSHA256 = ""

    /// Test seam: when set, the cache lives here instead of Application Support.
    public static var cacheDirectoryOverride: URL?

    public enum InstallError: Error, Equatable { case checksumNotConfigured, checksumMismatch, invalidCatalog, http(Int) }

    private static let lascMagic: [UInt8] = Array("LASC".utf8)

    /// ~/Library/Application Support/LiveAstroStudio/catalog/brightstars.bin (Application Support, NOT
    /// Caches — the OS can purge Caches, and re-downloading 32 MB on a whim is user-hostile).
    public static func cacheURL() -> URL {
        let dir = cacheDirectoryOverride ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstroStudio/catalog", isDirectory: true)
        return dir.appendingPathComponent("brightstars.bin")
    }

    /// Cheap "is a catalog installed?" for the UI gate — reads only the 12-byte header (magic + count),
    /// NOT the whole 32 MB file. (StarCatalog.installed() does the one full parse when the catalog is
    /// actually needed.)
    public static func isInstalled() -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: cacheURL()) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 12), head.count == 12 else { return false }
        let b = [UInt8](head)
        guard Array(b[0..<4]) == lascMagic else { return false }
        let count = UInt32(b[8]) | UInt32(b[9]) << 8 | UInt32(b[10]) << 16 | UInt32(b[11]) << 24
        return count > 0
    }

    /// Download from `url ?? remoteURL`, verify SHA-256 + that it parses as a non-empty catalog, then
    /// write it atomically into the cache. Throws (cache untouched) on missing checksum config, HTTP
    /// error, checksum mismatch, or invalid catalog. `progress` reports 0…1.
    public static func download(from url: URL? = nil, session: URLSession = .shared,
                                progress: @escaping (Double) -> Void) async throws {
        guard !expectedSHA256.isEmpty else { throw InstallError.checksumNotConfigured }
        let src = url ?? remoteURL
        progress(0)

        let delegate = ProgressDelegate(progress)
        let (tempURL, response) = try await session.download(from: src, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.http(http.statusCode)
        }
        let data = try Data(contentsOf: tempURL)
        progress(1)

        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hex == expectedSHA256.lowercased() else { throw InstallError.checksumMismatch }
        guard let cat = try? StarCatalog(data: data), cat.count > 0 else { throw InstallError.invalidCatalog }
        _ = cat

        let dest = cacheURL()
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // .atomic writes to a temp file in the same directory then renames — the cache never sees a
        // partial file, and this only runs AFTER verification, so it never holds a wrong one either.
        try data.write(to: dest, options: .atomic)
    }
}

/// Reports download progress for `URLSession.download(from:delegate:)` (efficient chunked download —
/// not a byte-by-byte stream).
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progress: (Double) -> Void
    init(_ progress: @escaping (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
    // Required by the protocol; the async download(from:delegate:) API hands us the temp URL directly,
    // so nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
