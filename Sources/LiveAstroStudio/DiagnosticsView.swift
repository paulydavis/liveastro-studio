import SwiftUI
import AppKit

struct DiagnosticsView: View {
    @Bindable var model: AppModel

    private let logMinHeight: CGFloat = 120

    // Session Health summary text (sessionStateText, sourceSummaryText, etc.) and
    // formatDuration now live on AppModel — shared with ControlView's "Copy Support
    // Bundle" footer action.

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
                        HealthItem(label: "State", value: model.sessionStateText)
                        HealthItem(label: "Source", value: model.sourceSummaryText)
                        HealthItem(label: "Folder", value: model.watchFolderSummaryText)
                        HealthItem(label: "Last update", value: model.lastUpdateSummaryText)
                        HealthItem(label: "Frames", value: model.framesSummaryText)
                        HealthItem(label: "Last rejection", value: model.lastRejectionSummaryText)
                        HealthItem(label: "OBS", value: model.obsSummaryText)
                        HealthItem(label: "Outputs", value: model.outputsSummaryText)
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
        State: \(model.sessionStateText)
        Source: \(model.sourceSummaryText)
        Folder: \(model.watchFolderSummaryText)
        Last update: \(model.lastUpdateSummaryText)
        Frames: \(model.framesSummaryText)
        Last rejection: \(model.lastRejectionSummaryText)
        OBS: \(model.obsSummaryText)
        Outputs: \(model.outputsSummaryText)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        model.log.append("Copied session health")
    }
}
