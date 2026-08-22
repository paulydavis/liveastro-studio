import Foundation
import CryptoKit

/// Downloads the Gaia bright-star catalog (~32 MB) on demand and caches it locally, so plate-solving
/// works in the shipped app WITHOUT bundling the CC BY-NC Gaia data (sub-project 3c). The download is
/// checksum- and parse-verified and written atomically, so the cache only ever holds a complete, valid
/// catalog — never a partial or wrong file that `isInstalled()` would accept.
public enum CatalogInstaller {
    /// GitHub Release asset URL for the pre-built G<=11 catalog. PLACEHOLDER until the asset is uploaded
    /// (see docs/CATALOG.md). With the placeholder, the download simply fails cleanly.
    public static var remoteURL = URL(string: "https://github.com/paulydavis/liveastro-studio/releases/download/catalog-v1/brightstars.bin")!
    /// Lowercase hex SHA-256 of the release asset. Empty string DISABLES the checksum (dev/fixture use).
    public static var expectedSHA256 = ""

    /// Test seam: when set, the cache lives here instead of Application Support.
    public static var cacheDirectoryOverride: URL?

    public enum InstallError: Error, Equatable { case checksumMismatch, invalidCatalog, http(Int) }

    /// ~/Library/Application Support/LiveAstroStudio/catalog/brightstars.bin (Application Support, NOT
    /// Caches — the OS can purge Caches, and re-downloading 32 MB on a whim is user-hostile).
    public static func cacheURL() -> URL {
        let dir = cacheDirectoryOverride ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstroStudio/catalog", isDirectory: true)
        return dir.appendingPathComponent("brightstars.bin")
    }

    /// True iff a parseable, non-empty catalog already exists in the cache.
    public static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: cacheURL()),
              let cat = try? StarCatalog(data: data), cat.count > 0 else { return false }
        return true
    }

    /// Download from `url ?? remoteURL`, verify SHA-256 (when `expectedSHA256` is set) and that it parses
    /// as a non-empty catalog, then write it atomically into the cache. Throws (cache untouched) on HTTP
    /// error, checksum mismatch, or invalid catalog. `progress` reports 0…1.
    public static func download(from url: URL? = nil, session: URLSession = .shared,
                                progress: @escaping (Double) -> Void) async throws {
        let src = url ?? remoteURL
        progress(0)
        let (bytes, response) = try await session.bytes(from: src)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.http(http.statusCode)
        }
        let total = response.expectedContentLength
        var data = Data(); data.reserveCapacity(total > 0 ? Int(total) : 4 << 20)
        var i = 0
        for try await b in bytes {
            data.append(b); i += 1
            if total > 0, i & 0x3FFFF == 0 { progress(min(1, Double(i) / Double(total))) }
        }
        progress(1)

        if !expectedSHA256.isEmpty {
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hex == expectedSHA256.lowercased() else { throw InstallError.checksumMismatch }
        }
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
