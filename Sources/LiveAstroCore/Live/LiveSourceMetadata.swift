import Foundation

/// Reads target/exposure from a live source folder's newest FITS sub, so a
/// generic rig (ASIAIR / NINA / ASI camera) needs no filename convention.
public enum LiveSourceMetadata {
    /// The newest readable .fit/.fits in `folder`, parsed for OBJECT (target) and
    /// EXPTIME (exposure). Scans newest-first and SKIPS any file whose header can't
    /// be read — a mid-write live capture or a truncated/zero-byte sub — falling
    /// back to the next newest rather than giving up. nil only if none parse. Reads
    /// only a bounded header prefix, not the (potentially 50 MB) pixel data.
    public static func newestFITSMetadata(inFolder folder: URL)
        -> (object: String?, exposureSeconds: Double?, fileExtension: String)? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let fits = items.filter { ["fit", "fits"].contains($0.pathExtension.lowercased()) }
        guard !fits.isEmpty else { return nil }
        let newestFirst = fits.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da > db
        }
        for url in newestFirst {
            // Bounded header read: FITS headers are small 2880-byte blocks; 256 KB is
            // far more than any real header, so we avoid pulling the full sub.
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            guard let header = try? FITSReader.readHeader(prefix) else { continue }
            let meta = SourceMetadata(fitsKeywords: header.keywords)
            return (meta.object, meta.exposureSeconds, url.pathExtension.lowercased())
        }
        return nil
    }
}
