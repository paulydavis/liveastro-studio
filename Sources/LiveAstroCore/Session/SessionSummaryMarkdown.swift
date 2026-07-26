import Foundation

public enum SessionSummaryMarkdown {
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func render(manifest: SessionManifest) -> String {
        var lines: [String] = []
        lines.append("# Session Summary")
        lines.append("")
        lines.append("## Session")
        lines.append("")
        lines.append("| Field | Value |")
        lines.append("| --- | --- |")
        lines.append(row("Session id", manifest.sessionId))
        lines.append(row("Target", valueOrDash(manifest.targetName)))
        lines.append(row("Started", format(manifest.startTime)))
        lines.append(row("Ended", manifest.endTime.map(format) ?? "—"))
        lines.append(row("Sub exposure", formatSeconds(manifest.subExposureSeconds)))
        lines.append(row("Snapshots", "\(manifest.snapshots.count)"))
        lines.append("")
        lines.append("## Equipment and site")
        lines.append("")
        lines.append("| Field | Value |")
        lines.append("| --- | --- |")
        lines.append(row("Telescope", valueOrDash(manifest.telescope)))
        lines.append(row("Camera", valueOrDash(manifest.camera)))
        lines.append(row("Mount", valueOrDash(manifest.mount)))
        lines.append(row("Filter", valueOrDash(manifest.filter)))
        lines.append(row("Location", valueOrDash(manifest.locationLabel)))
        lines.append(row("Bortle", manifest.bortle.map(String.init) ?? "—"))
        if !manifest.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(row("Notes", manifest.notes))
        }
        lines.append("")
        lines.append("## Final stack")
        lines.append("")
        lines.append("| Field | Value |")
        lines.append("| --- | --- |")
        lines.append(row("Master expected", manifest.masterExpected.map { $0 ? "yes" : "no" } ?? "unknown"))
        lines.append(row("Master outcome", manifest.masterOutcome?.rawValue ?? "unknown"))
        if let stackFrameCount = manifest.stackFrameCount {
            let integration = Double(stackFrameCount) * manifest.subExposureSeconds
            lines.append(row("Current-stack frames", "\(stackFrameCount)"))
            lines.append(row("Current-stack integration",
                             IntegrationFormat.caption(seconds: integration,
                                                       frames: stackFrameCount,
                                                       subSeconds: manifest.subExposureSeconds)))
        } else {
            lines.append(row("Current-stack frames", "unknown"))
        }
        lines.append(row("Session accepted",
                         manifest.sessionAcceptedCount.map(String.init) ?? "\(manifest.snapshots.count)"))
        lines.append(row("Session rejected", manifest.sessionRejectedCount.map(String.init) ?? "unknown"))
        lines.append("")
        lines.append("## Files to inspect")
        lines.append("")
        lines.append("- `session-summary.md` — this human-readable summary")
        lines.append("- `manifest.json` — machine-readable session record")
        lines.append("- `master.fit` — final native-stack master when written")
        lines.append("- `replay.mp4` — session replay when enabled")
        lines.append("- `latest.png` — latest preview image")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func write(manifest: SessionManifest, to sessionDirectory: URL) throws {
        let url = sessionDirectory.appendingPathComponent("session-summary.md")
        try render(manifest: manifest).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func row(_ field: String, _ value: String) -> String {
        "| \(escape(field)) | \(escape(value)) |"
    }

    private static func valueOrDash(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : value
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        seconds.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(seconds))s" : "\(seconds)s"
    }
}
