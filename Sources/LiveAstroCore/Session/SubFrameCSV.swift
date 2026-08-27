import Foundation

/// Serializes per-sub quality records to CSV (spec §Persistence & outputs).
/// Companion to SessionFrameCSV; same quoting rule (a field containing a comma,
/// quote, or newline is wrapped in double quotes with internal quotes doubled)
/// and the same date formatter, so the two CSVs agree.
public enum SubFrameCSV {
    private static let header = "index,timestamp,source_file,star_count,background_sigma,weight,outcome,rejection_reason,rejected_by_user"

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func string(from records: [SubFrameRecord]) -> String {
        var out = header + "\n"
        for r in records {
            let cols = [
                String(r.index),
                dateFormatter.string(from: r.timestamp),
                r.sourceFile,
                String(r.starCount),
                String(r.backgroundSigma),
                String(r.weight),
                r.outcome.rawValue,
                r.rejectionReason ?? "",
                r.rejectedByUser ? "true" : "false"
            ].map(escape)
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
