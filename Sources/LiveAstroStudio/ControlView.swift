import SwiftUI
import AppKit
import LiveAstroCore

struct ControlView: View {
    @Environment(AppModel.self) private var model

    @State private var outputFootprintText = "not checked"

    private var hasSessionOutputs: Bool {
        !model.isRunning && (model.replayURL != nil || model.lastSessionDirectory != nil)
    }

    private var latestMasterURL: URL? {
        guard let dir = model.lastSessionDirectory else { return nil }
        let master = dir.appendingPathComponent("master.fit")
        return FileManager.default.fileExists(atPath: master.path) ? master : nil
    }

    private var latestImageURL: URL? {
        guard let dir = model.lastSessionDirectory else { return nil }
        let latest = dir.appendingPathComponent("latest.png")
        return FileManager.default.fileExists(atPath: latest.path) ? latest : nil
    }

    private var sessionSummaryURL: URL? {
        guard let dir = model.lastSessionDirectory else { return nil }
        let summary = dir.appendingPathComponent("session-summary.md")
        return FileManager.default.fileExists(atPath: summary.path) ? summary : nil
    }

    private var frameSummaryURL: URL? {
        guard let dir = model.lastSessionDirectory else { return nil }
        let csv = dir.appendingPathComponent("frame-summary.csv")
        return FileManager.default.fileExists(atPath: csv.path) ? csv : nil
    }

    private var subFramesURL: URL? {
        guard let dir = model.lastSessionDirectory else { return nil }
        let csv = dir.appendingPathComponent(SubFrameCSV.filename)
        return FileManager.default.fileExists(atPath: csv.path) ? csv : nil
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let version, !version.isEmpty else { return "LiveAstro dev" }
        if let build, !build.isEmpty, build != version {
            return "LiveAstro v\(version) (build \(build))"
        }
        return "LiveAstro v\(version)"
    }

    // Session Health summary text (sessionStateText, sourceSummaryText, etc.) used by
    // the "Copy Support Bundle" action below now lives on AppModel — shared with
    // DiagnosticsView's Session Health grid.

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TabView(selection: $model.setupSubTab) {
                CaptureSettingsView(model: model)
                    .tabItem { Label("Capture", systemImage: "camera") }
                    .tag(AppModel.SetupSubTab.capture)
                DisplaySettingsView(model: model)
                    .tabItem { Label("Display", systemImage: "slider.horizontal.3") }
                    .tag(AppModel.SetupSubTab.display)
                StatsView(model: model)
                    .tabItem { Label("Stats", systemImage: "chart.bar") }
                    .tag(AppModel.SetupSubTab.stats)
                BroadcastSettingsView(model: model)
                    .tabItem { Label("Broadcast", systemImage: "dot.radiowaves.left.and.right") }
                    .tag(AppModel.SetupSubTab.broadcast)
                DiagnosticsView(model: model)
                    .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                    .tag(AppModel.SetupSubTab.diagnostics)
            }

            Divider()

            controlFooter
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .alert("LiveAstro", isPresented: $model.isShowingError) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    // Fixed footer — always visible regardless of which Setup sub-tab is selected.
    @ViewBuilder
    private var controlFooter: some View {
        VStack(spacing: 8) {
            HStack {
                if model.isRunning {
                    Button("End Session", role: .destructive) { model.endSession() }
                        .disabled(model.importer.isGeneratingReplay)
                } else {
                    Button("Start Session") { model.startSession() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.importer.isImporting)
                }
                Spacer()
                Button {
                    model.liveSource.startSeestarLive()
                } label: { Label("Start Seestar", systemImage: "dot.radiowaves.left.and.right") }
                .help("Auto-detect the mounted Seestar folder, start relaying its 10s subs, and begin native stacking — one tap.")
                .disabled(model.isRunning || model.importer.isImporting || model.liveSource.isDetecting)
                Button {
                    model.liveSource.startASIAIRLive()
                } label: { Label("Start ASIAIR", systemImage: "camera.aperture") }
                .help("Auto-detect the ASIAIR's Autorun/Light folder, relay its subs, and begin native stacking — one tap.")
                .disabled(model.isRunning || model.importer.isImporting || model.liveSource.isDetecting)
                Button("Live from Folder / NINA…") { model.pickNativeWatchFolderLive() }
                    .help("Live-stack subs from any folder your rig writes to, including NINA or another FITS capture app.")
                    .disabled(model.isRunning || model.importer.isImporting || model.liveSource.isDetecting)
                Button("Stack Previous Shoot…") { model.pickImportFolder() }
                    .disabled(model.isRunning || model.importer.isImporting)
                    .help("Select a folder of previously captured FITS light frames to stack offline, with progress tracking and Cancel support.")
            }
            // Go Live / End Broadcast — decoupled from session start.
            HStack {
                switch model.broadcast.broadcastState {
                case .idle:
                    Button("Go Live") { model.broadcast.goLive() }
                        .help("Broadcast the live stack to YouTube via OBS (configure the YouTube key in OBS ▸ Settings ▸ Stream first).")
                case .unknown:
                    // Review7: initial state — OBS output state never confirmed, so
                    // no idle claim. Go Live still works one-click: it connects and
                    // reconciles with OBS's actual state first (adopting an
                    // already-live stream instead of double-starting it).
                    HStack(spacing: 10) {
                        Button("Go Live") { model.broadcast.goLive() }
                            .help("Connect to OBS, sync with its actual stream state, and start broadcasting if nothing is already live.")
                        Text("OBS not checked yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .connecting:
                    HStack { ProgressView().controlSize(.small); Text("Connecting OBS…") }
                case .live:
                    HStack(spacing: 10) {
                        Button("End Broadcast", role: .destructive) { model.broadcast.endBroadcast() }
                        if let h = model.broadcast.streamHealth {
                            Text("● LIVE · \(model.formatDuration(h.durationSeconds)) · \(h.skippedFrames) dropped · \(Int((h.congestion * 100).rounded()))% cong")
                                .foregroundStyle(.red).font(.caption)
                        }
                    }
                case .endingSession:
                    // Review5 P2: the stream deliberately stays live until the replay
                    // finishes — don't offer Go Live, and keep showing live health truth.
                    // Review6: offer End Broadcast as an operator override (stream down
                    // NOW while the replay renders).
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Ending broadcast…")
                        Button("End Broadcast", role: .destructive) { model.broadcast.endBroadcast() }
                            .help("Stop the stream now instead of waiting for the replay to finish rendering.")
                        if let h = model.broadcast.streamHealth {
                            Text("● LIVE · \(model.formatDuration(h.durationSeconds)) · \(h.skippedFrames) dropped · \(Int((h.congestion * 100).rounded()))% cong")
                                .foregroundStyle(.red).font(.caption)
                        }
                    }
                case .stopping:
                    HStack { ProgressView().controlSize(.small); Text("Stopping…") }
                case .stopUnconfirmed:
                    // Review6 P1: the stop was never confirmed — OBS may still be live.
                    // Honest state: block Go Live and offer Retry.
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("OBS may still be live — check OBS")
                            .font(.caption)
                        Button("Retry") { model.broadcast.retryStop() }
                            .help("Re-attempt the stop and confirm the stream and recording are down.")
                    }
                }
                Spacer()
            }
            if model.isRunning && model.sourceMode == .nativeStack {
                HStack {
                    Text("accepted \(model.acceptedCount) · rejected \(model.rejectedCount)")
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button("Reseed Reference") { model.reseedReference() }
                        .help("Replace the alignment reference frame with the latest accepted sub so subsequent subs align to it.")
                }
            }
            if model.importer.isImporting {
                VStack(spacing: 4) {
                    ProgressView(value: Double(model.importer.importProcessed),
                                 total: Double(max(model.importer.importTotal, 1)))
                    HStack {
                        Text("\(model.importer.importProcessed) / \(model.importer.importTotal)")
                        Spacer()
                        Text("✓ \(model.acceptedCount)  ✗ \(model.rejectedCount)").foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { model.importer.cancelImport() }
                    }.font(.caption)
                }.padding(.horizontal)
            }
            if !model.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Session Outputs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Output footprint: \(outputFootprintText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("Refresh Sizes") { refreshOutputFootprint() }
                            .help("Calculate the size of the LiveAstro output root and latest session folder.")
                        Button("Open Sessions Folder") { openSessionsRoot() }
                            .help("Open the root folder where LiveAstro writes session outputs.")
                        Button("Regenerate Replay…") { pickSessionDirectory() }
                            .disabled(model.importer.isGeneratingReplay)
                    }

                    if hasSessionOutputs {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Button("Open Replay") { openReplay() }
                                    .disabled(model.replayURL == nil)
                                    .help("Open the latest replay video with the default macOS app.")

                                Button("Reveal Replay") { revealReplay() }
                                    .disabled(model.replayURL == nil)
                                    .help("Show the latest replay video in Finder.")

                                Button("Open Session Folder") { openSessionFolder() }
                                    .disabled(model.lastSessionDirectory == nil)
                                    .help("Open the folder containing this session's manifest, snapshots, replay, and native master when present.")

                                if latestImageURL != nil {
                                    Button("Open Latest Image") { openLatestImage() }
                                        .help("Open the session's latest.png monitor image.")

                                    Button("Reveal latest.png") { revealLatestImage() }
                                        .help("Show the session's latest.png monitor image in Finder.")
                                }

                                if latestMasterURL != nil {
                                    Button("Open master.fit") { openMaster() }
                                        .help("Open master.fit in your default FITS app (e.g. Siril) for further processing.")
                                    Button("Reveal master.fit") { revealMaster() }
                                        .help("Show the native stacking master in Finder.")
                                } else if model.lastSessionDirectory != nil {
                                    Button("No master.fit") {}
                                        .disabled(true)
                                        .help("Native sessions write master.fit when a current stack exists. Siril/external stacker sessions may not create one.")
                                }

                                Spacer()
                            }

                            HStack(spacing: 8) {
                                if sessionSummaryURL != nil {
                                    Button("Open Summary") { openSessionSummary() }
                                        .help("Open the session-summary.md human-readable session report.")
                                }

                                if frameSummaryURL != nil {
                                    Button("Open Frame CSV") { openFrameSummary() }
                                        .help("Open the frame-summary.csv per-snapshot table.")
                                }

                                if subFramesURL != nil {
                                    Button("Open sub-frames.csv") { openSubFrames() }
                                        .help("Open the per-sub quality + rejection table.")
                                }

                                Spacer()

                                Button("Copy Support Bundle") { copySupportBundle() }
                                    .help("Copy health, output paths, and recent log lines for sharing or debugging.")

                                Button("Copy Summary") { copySessionSummary() }
                                    .help("Copy target, output paths, and accepted/rejected frame counts.")
                            }
                        }
                        .font(.caption)
                    } else {
                        Text("Finish a session or stack a previous shoot to see output shortcuts here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if model.processorBackend != .none, model.sourceMode == .nativeStack, let dir = model.lastSessionDirectory {
                Button(model.importer.isProcessing ? "Processing…" : "Process master") {
                    model.importer.processMaster(sessionDirectory: dir)
                }
                .disabled(model.importer.isProcessing
                          || (model.processorBackend == .graxpert && GraXpertProcessor.defaultExecutable() == nil))
                .help(model.processorBackend == .graxpert
                      ? (GraXpertProcessor.defaultExecutable() == nil
                         ? "GraXpert not found — install from graxpert.com"
                         : "Run GraXpert on the last stacked master → master_processed FITS")
                      : "Run the native denoiser on the last stacked master → master_processed FITS")
            }
            if model.importer.isGeneratingReplay { ProgressView("Rendering replay…") }
            Text(appVersionText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func pickSessionDirectory() {
        let panel = model.makeDirectoryPanel(title: "Choose Session Directory",
                                             message: "Select a past session folder containing manifest.json")
        let liveAstro = model.liveAstroRoot
        if FileManager.default.fileExists(atPath: liveAstro.path) {
            panel.directoryURL = liveAstro
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.importer.regenerateReplay(sessionDirectory: url)
        }
    }

    private func openReplay() {
        guard let url = model.replayURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func openLatestImage() {
        guard let url = latestImageURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSessionSummary() {
        guard let url = sessionSummaryURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func openFrameSummary() {
        guard let url = frameSummaryURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSubFrames() {
        guard let url = subFramesURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealReplay() {
        guard let url = model.replayURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func revealLatestImage() {
        guard let url = latestImageURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func refreshOutputFootprint() {
        do {
            let rootBytes = try DirectoryFootprint.byteCount(at: model.liveAstroRoot)
            let rootSize = ByteCountFormatter.string(fromByteCount: rootBytes, countStyle: .file)
            if let session = model.lastSessionDirectory {
                let sessionBytes = try DirectoryFootprint.byteCount(at: session)
                let sessionSize = ByteCountFormatter.string(fromByteCount: sessionBytes, countStyle: .file)
                outputFootprintText = "root \(rootSize) · last session \(sessionSize)"
            } else {
                outputFootprintText = "root \(rootSize)"
            }
            model.log.append("Refreshed output footprint")
        } catch {
            outputFootprintText = "unavailable"
            model.log.append("Could not calculate output footprint: \(error.localizedDescription)")
        }
    }

    private func openSessionFolder() {
        guard let url = model.lastSessionDirectory else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSessionsRoot() {
        let url = model.liveAstroRoot
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
            model.log.append("Opened sessions folder")
        } catch {
            model.errorMessage = "Could not open sessions folder: \(error.localizedDescription)"
        }
    }

    private func openMaster() {
        guard let url = latestMasterURL else { return }
        NSWorkspace.shared.open(url)   // opens in the user's default FITS app (Siril if configured)
    }

    private func revealMaster() {
        guard let url = latestMasterURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copySupportBundle() {
        let target = model.targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionPath = model.lastSessionDirectory?.path ?? "(none)"
        let replayPath = model.replayURL?.path ?? "(none)"
        let masterPath = latestMasterURL?.path ?? "(none)"
        let latestImagePath = latestImageURL?.path ?? "(none)"
        let sessionSummaryPath = sessionSummaryURL?.path ?? "(none)"
        let frameSummaryPath = frameSummaryURL?.path ?? "(none)"
        let logTail = model.log.suffix(logDisplayCap).joined(separator: "\n")
        let summary = """
        LiveAstro Support Bundle
        App: \(appVersionText)

        Session Health
        State: \(model.sessionStateText)
        Source: \(model.sourceSummaryText)
        Folder: \(model.watchFolderSummaryText)
        Last update: \(model.lastUpdateSummaryText)
        Frames: \(model.framesSummaryText)
        Last rejection: \(model.lastRejectionSummaryText)
        OBS: \(model.obsSummaryText)
        Outputs: \(model.outputsSummaryText)

        Session Outputs
        Target: \(target.isEmpty ? "(untitled)" : target)
        Session folder: \(sessionPath)
        Replay: \(replayPath)
        Latest image: \(latestImagePath)
        Master: \(masterPath)
        Session summary: \(sessionSummaryPath)
        Frame summary CSV: \(frameSummaryPath)
        Output footprint: \(outputFootprintText)

        Recent Log
        \(logTail.isEmpty ? "(empty)" : logTail)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        model.log.append("Copied support bundle")
    }

    private func copySessionSummary() {
        let target = model.targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionPath = model.lastSessionDirectory?.path ?? "(none)"
        let replayPath = model.replayURL?.path ?? "(none)"
        let masterPath = latestMasterURL?.path ?? "(none)"
        let latestImagePath = latestImageURL?.path ?? "(none)"
        let sessionSummaryPath = sessionSummaryURL?.path ?? "(none)"
        let frameSummaryPath = frameSummaryURL?.path ?? "(none)"
        let summary = """
        LiveAstro Session
        Target: \(target.isEmpty ? "(untitled)" : target)
        Session folder: \(sessionPath)
        Replay: \(replayPath)
        Latest image: \(latestImagePath)
        Master: \(masterPath)
        Session summary: \(sessionSummaryPath)
        Frame summary CSV: \(frameSummaryPath)
        Accepted frames: \(model.acceptedCount)
        Rejected frames: \(model.rejectedCount)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        model.log.append("Copied session summary")
    }
}
