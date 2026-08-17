import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum SnapshotError: Error { case encodeFailed }

public final class SnapshotRecorder {
    private let sessionDirectory: URL

    /// Snapshots (`%04d.png` + `latest.png`) only feed the 1920×1080 replay and the on-screen
    /// preview, so they're capped at 2560 px on the long edge (2× the replay, crisp on 4K/5K).
    /// This turns a ~7 s full-res 26 MP PNG encode per frame into ~0.5 s — the import bottleneck.
    /// master.fit and the manifest stats (from `linear`) stay full resolution.
    static let maxSnapshotLongEdge = 2560

    public init(sessionDirectory: URL) { self.sessionDirectory = sessionDirectory }

    /// Aspect-preserving downscale so the snapshot's long edge ≤ `maxLongEdge`. Returns the
    /// image unchanged when already within bounds, or if a context can't be made — a snapshot
    /// is never lost to a resize failure.
    static func downscaled(_ image: CGImage, maxLongEdge: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge else { return image }
        let scale = Double(maxLongEdge) / Double(longEdge)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Saves a display-ready (post-stretch) PNG and returns its manifest record (spec §5.7).
    public func save(cgImage: CGImage, linear: AstroImage, sourceFile: String,
                     index: Int, timestamp: Date,
                     estimatedIntegrationSeconds: Double) throws -> SnapshotRecord {
        let name = String(format: "snapshots/%04d.png", index)
        let url = sessionDirectory.appendingPathComponent(name)
        // Destination creation is nil only for malformed URLs/UTIs; the session
        // directory itself is guaranteed by SessionManager. A missing snapshots/
        // subdirectory surfaces later as a Finalize failure.
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError.encodeFailed
        }
        let preview = Self.downscaled(cgImage, maxLongEdge: Self.maxSnapshotLongEdge)
        CGImageDestinationAddImage(dest, preview, nil)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotError.encodeFailed }
        updateLatestImage(from: url)

        // AstroImage.init computes stats for every channel; stats.count == channels >= 1.
        let stats = linear.stats[0]
        return SnapshotRecord(index: index, timestamp: timestamp, sourceFile: sourceFile,
                              snapshotFile: name,
                              estimatedIntegrationSeconds: estimatedIntegrationSeconds,
                              width: linear.width, height: linear.height,
                              mean: stats.mean, median: stats.median, stddev: stats.stddev)
    }

    private func updateLatestImage(from snapshotURL: URL) {
        let latestURL = sessionDirectory.appendingPathComponent("latest.png")
        let tempURL = sessionDirectory.appendingPathComponent(".latest-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: snapshotURL, to: tempURL)
            if FileManager.default.fileExists(atPath: latestURL.path) {
                _ = try FileManager.default.replaceItemAt(latestURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: latestURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
