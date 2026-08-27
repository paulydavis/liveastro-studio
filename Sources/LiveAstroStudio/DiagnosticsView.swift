import SwiftUI
import AppKit

struct DiagnosticsView: View {
    @Bindable var model: AppModel

    private let logDisplayCap = 200
    private let logMinHeight: CGFloat = 120

    // Session Health summary text — mirrors the equivalents in ControlView (used
    // there by the Session Outputs "Copy Support Bundle" action). Kept as a small,
    // single-destination duplication rather than threading a shared dependency
    // between the pinned footer and this tab for eight one-line string formatters.
    private var sessionStateText: String {
        if model.liveSource.isDetecting { return "Detecting source" }
        if model.importer.isImporting { return "Importing" }
        if model.importer.isGeneratingReplay { return "Rendering replay" }
        if model.isRunning { return "Running" }
        return "Idle"
    }

    private var sourceSummaryText: String {
        switch model.sourceMode {
        case .nativeStack:
            return "Native stacking"
        case .stackerOutput:
            return "Siril / external stacker"
        }
    }

    private var watchFolderSummaryText: String {
        model.watchFolder?.path ?? "(none selected)"
    }

    private var lastUpdateSummaryText: String {
        guard let record = model.latestRecord else { return model.integrationCaption }
        return "#\(record.index) · \(record.snapshotFile)"
    }

    private var framesSummaryText: String {
        "accepted \(model.acceptedCount) · rejected \(model.rejectedCount)"
    }

    private var lastRejectionSummaryText: String {
        guard let line = model.log.last(where: { $0.hasPrefix("✗ rejected ") }) else {
            return "(none)"
        }
        let prefix = "✗ rejected "
        if line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }

    private var obsSummaryText: String {
        switch model.broadcast.broadcastState {
        case .idle:
            return "idle"
        case .unknown:
            return "not checked"
        case .connecting:
            return "connecting"
        case .live:
            if let h = model.broadcast.streamHealth {
                return "live · \(formatDuration(h.durationSeconds)) · \(h.skippedFrames) dropped · \(Int((h.congestion * 100).rounded()))% congestion"
            }
            return "live"
        case .endingSession:
            return "ending session"
        case .stopping:
            return "stopping"
        case .stopUnconfirmed:
            return "may still be live"
        }
    }

    private var outputsSummaryText: String {
        if model.replayURL != nil { return "replay ready" }
        if model.lastSessionDirectory != nil { return "session folder ready" }
        return "no finished session yet"
    }

    var body: some View {
        ScrollView {
            Form {
                Section {
                    HStack {
                        Text("Session Health")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Watch Folder") { openWatchFolder() }
                            .font(.caption)
                            .disabled(model.watchFolder == nil)
                            .help("Open the folder LiveAstro is currently watching for FITS files.")
                        Button("Copy Health") { copyHealthSnapshot() }
                            .font(.caption)
                            .help("Copy the current session health snapshot for sharing or debugging.")
                    }

                    LazyVGrid(columns: [
                        GridItem(.flexible(minimum: 120), alignment: .leading),
                        GridItem(.flexible(minimum: 120), alignment: .leading),
                        GridItem(.flexible(minimum: 120), alignment: .leading),
                        GridItem(.flexible(minimum: 120), alignment: .leading)
                    ], alignment: .leading, spacing: 8) {
                        HealthItem(label: "State", value: sessionStateText)
                        HealthItem(label: "Source", value: sourceSummaryText)
                        HealthItem(label: "Folder", value: watchFolderSummaryText)
                        HealthItem(label: "Last update", value: lastUpdateSummaryText)
                        HealthItem(label: "Frames", value: framesSummaryText)
                        HealthItem(label: "Last rejection", value: lastRejectionSummaryText)
                        HealthItem(label: "OBS", value: obsSummaryText)
                        HealthItem(label: "Outputs", value: outputsSummaryText)
                    }
                }
                Section {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.log.suffix(logDisplayCap).enumerated()), id: \.offset) {
                                Text($0.element).font(.system(.caption, design: .monospaced))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: logMinHeight)
                } header: {
                    HStack {
                        Text("Log")
                        Spacer()
                        Button("Copy Log") { copyLogTail() }
                            .font(.caption)
                            .disabled(model.log.isEmpty)
                            .help("Copy the visible recent log lines for sharing or debugging.")
                    }
                }
            }
            .formStyle(.grouped)
            .background(AlwaysVisibleScroller())
        }
        .scrollIndicators(.visible)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    private func openWatchFolder() {
        guard let url = model.watchFolder else { return }
        NSWorkspace.shared.open(url)
        model.log.append("Opened watch folder")
    }

    private func copyLogTail() {
        let tail = model.log.suffix(logDisplayCap).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tail, forType: .string)
        model.log.append("Copied log tail")
    }

    private func copyHealthSnapshot() {
        let summary = """
        LiveAstro Session Health
        State: \(sessionStateText)
        Source: \(sourceSummaryText)
        Folder: \(watchFolderSummaryText)
        Last update: \(lastUpdateSummaryText)
        Frames: \(framesSummaryText)
        Last rejection: \(lastRejectionSummaryText)
        OBS: \(obsSummaryText)
        Outputs: \(outputsSummaryText)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        model.log.append("Copied session health")
    }
}
