import Foundation

/// Reads target/exposure from a live source folder's newest FITS sub, so a
/// generic rig (ASIAIR / NINA / ASI camera) needs no filename convention.
public enum LiveSourceMetadata {
    /// The newest .fit/.fits in `folder`, parsed for OBJECT (target) and
    /// EXPTIME (exposure). nil if there is no readable FITS. Reads only a bounded
    /// header prefix, not the (potentially 50 MB) pixel data.
    public static func newestFITSMetadata(inFolder folder: URL)
        -> (object: String?, exposureSeconds: Double?, fileExtension: String)? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let fits = items.filter { ["fit", "fits"].contains($0.pathExtension.lowercased()) }
        guard !fits.isEmpty else { return nil }
        let newest = fits.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
        guard let url = newest else { return nil }
        let ext = url.pathExtension.lowercased()
        // Bounded header read: FITS headers are small 2880-byte blocks; 256 KB is
        // far more than any real header, so we avoid pulling the full sub.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        guard let header = try? FITSReader.readHeader(prefix) else { return nil }
        let meta = SourceMetadata(fitsKeywords: header.keywords)
        return (meta.object, meta.exposureSeconds, ext)
    }
}
