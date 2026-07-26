import Foundation

public enum SessionFrameCSV {
    public static let filename = "frame-summary.csv"

    private static let header = [
        "index",
        "timestamp",
        "source_file",
        "snapshot_file",
        "estimated_integration_seconds",
        "sub_exposure_seconds",
        "width",
        "height",
        "mean",
        "median",
        "stddev"
    ]

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func render(manifest: SessionManifest) -> String {
        var rows = [header.joined(separator: ",")]
        rows.append(contentsOf: manifest.snapshots.map { record in
            [
                "\(record.index)",
                dateFormatter.string(from: record.timestamp),
                record.sourceFile,
                record.snapshotFile,
                "\(record.estimatedIntegrationSeconds)",
                "\(manifest.subExposureSeconds)",
                "\(record.width)",
                "\(record.height)",
                "\(record.mean)",
                "\(record.median)",
                "\(record.stddev)"
            ].map(csvField).joined(separator: ",")
        })
        return rows.joined(separator: "\n") + "\n"
    }

    public static func write(manifest: SessionManifest, to sessionDirectory: URL) throws {
        let url = sessionDirectory.appendingPathComponent(filename)
        try render(manifest: manifest).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") ||
              value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
