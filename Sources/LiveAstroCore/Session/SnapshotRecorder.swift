import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum SnapshotError: Error { case encodeFailed }

public final class SnapshotRecorder {
    private let sessionDirectory: URL

    public init(sessionDirectory: URL) { self.sessionDirectory = sessionDirectory }

    /// Saves a display-ready (post-stretch) PNG and returns its manifest record (spec §5.7).
    public func save(cgImage: CGImage, linear: AstroImage, sourceFile: String,
                     index: Int, timestamp: Date,
                     estimatedIntegrationSeconds: Double) throws -> SnapshotRecord {
        let name = String(format: "snapshots/%04d.png", index)
        let url = sessionDirectory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotError.encodeFailed }

        let stats = linear.stats[0]
        return SnapshotRecord(index: index, timestamp: timestamp, sourceFile: sourceFile,
                              snapshotFile: name,
                              estimatedIntegrationSeconds: estimatedIntegrationSeconds,
                              width: linear.width, height: linear.height,
                              mean: stats.mean, median: stats.median, stddev: stats.stddev)
    }
}
