import SwiftUI
import AppKit
import LiveAstroCore

struct ControlView: View {
    @Environment(AppModel.self) private var model

    @State private var outputFootprintText = "not checked"
    @State private var artifactDirectory: URL?
    @State private var artifactNames: Set<String> = []
    private struct ArtifactRequest: Hashable {
        let directory: URL?
        let running: Bool
    }
    private var artifactRequest: ArtifactRequest {
        ArtifactRequest(directory: model.lastSessionDirectory, running: model.isRunning || model.importer.isImporting)
    }

    private var hasSessionOutputs: Bool {
        !model.isRunning && (model.replayURL != nil || model.lastSessionDirectory != nil)
    }

    private var latestMasterURL: URL? {
        artifactURL("master.fit")
    }

    private var latestImageURL: URL? {
        artifactURL("latest.png")
    }

    private var sessionSummaryURL: URL? {
        artifactURL("session-summary.md")
    }

    private var frameSummaryURL: URL? {
        artifactURL("frame-summary.csv")
    }

    private var subFramesURL: URL? {
        artifactURL(SubFrameCSV.filename)
    }

    private func artifactURL(_ name: String) -> URL? {
        guard let directory = model.lastSessionDirectory, directory == artifactDirectory,
              artifactNames.contains(name) else { return nil }
        return directory.appendingPathComponent(name)
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
        let inputRequestID = model.pendingSessionStart?.id
        @Bindable var model = model
        VStack(spacing: 0) {
            SetupBrandHeader()
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
                Group {
                    if let check = model.obsConnectionCheck, let recording = model.obsLocalRecording {
                        OBSConnectionCheckView(check: check, recording: recording)
                    } else { BroadcastSettingsView(model: model) }
                }
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
        .background(SetupStyle.background)
        .environment(\.colorScheme, .dark)
        .tint(SetupStyle.accent)
        .task(id: artifactRequest) {
            let request = artifactRequest
            artifactDirectory = nil
            artifactNames = []
            guard !request.running, let directory = request.directory else { return }
            do {
                let names = try await model.sessionArtifactNames(in: directory)
                guard !Task.isCancelled, artifactRequest == request else { return }
                artifactNames = names
                artifactDirectory = directory
            } catch {
                guard !Task.isCancelled, artifactRequest == request else { return }
                model.log.append("Could not check session outputs: \(error.localizedDescription)")
            }
        }
        .alert("LiveAstro", isPresented: $model.isShowingError) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        // Subs already in the folder are a QUESTION, not a silent decision: a stale folder
        // used to be stacked into a new session without a word.
        .confirmationDialog("Subs are already in this folder",
                            isPresented: Binding(
                                get: { model.pendingSessionStart != nil },
                                // Any dismissal path (Escape, click-away) means cancel: the
                                // safe direction, since cancelling starts nothing. A .constant
                                // binding here would wedge a dialog SwiftUI cannot close.
                                set: { if !$0, let inputRequestID {
                                    model.resolvePendingSessionStart(.cancel, requestID: inputRequestID)
                                } }),
                            titleVisibility: .visible) {
            Button("Stack existing + new") {
                if let inputRequestID { model.resolvePendingSessionStart(.stackExistingAndNew, requestID: inputRequestID) }
            }
            Button("New arrivals only") {
                if let inputRequestID { model.resolvePendingSessionStart(.newArrivalsOnly, requestID: inputRequestID) }
            }
            Button("Cancel", role: .cancel) {
                if let inputRequestID { model.resolvePendingSessionStart(.cancel, requestID: inputRequestID) }
            }
        } message: {
            Text(model.pendingSessionStartMessage ?? "")
        }
    }

    /// A standing statement about the session's input. Deliberately persistent: the case this
    /// exists for — a filename filter matching nothing — is invisible in a scrolling log.
    @ViewBuilder
    private var sessionInputBanner: some View {
        switch model.sessionInputStatus {
        case .preparingBaseline(let completed, let total):
            HStack {
                ProgressView().controlSize(.small)
                Text(total == 0 ? "Reading session input…" : "Preparing content baseline: \(completed)/\(total) subs…")
                    .font(.callout)
                Button("Cancel") { model.cancelSessionInputPreparation() }
            }
            .padding(.vertical, 4)
        case .waitingForFirstSub(let folder, let filter, let unmatched):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(filter.map { "No subs matching “\($0)” found. Waiting for new files." }
                         ?? "No subs found. Waiting for new files.")
                        .font(.callout)
                    Text(unmatched > 0
                         ? "\(folder.path) — \(unmatched) other file(s) present, none match the filter."
                         : folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: { Image(systemName: "clock.badge.questionmark") }
            .padding(.vertical, 4)
        case .failed(let reason):
            Label {
                Text("Can't start session: \(reason)")
                    .font(.callout)
            } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .foregroundStyle(.orange)
            .padding(.vertical, 4)
        case nil:
            EmptyView()
        }
    }

    // Fixed footer — always visible regardless of which Setup sub-tab is selected.
    @ViewBuilder
    private var controlFooter: some View {
        VStack(spacing: 8) {
            sessionInputBanner
            if model.liveSource.canCancelDetection {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Looking for camera or folder input…").font(.callout)
                    Button("Cancel source search") { model.liveSource.cancelDetection() }
                        .help("Return to idle now. A blocked filesystem read may finish later, but its result will not start a session.")
                }
            }
            if let status = model.cleanStackStatus {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.message).font(.caption)
                    if let progress = model.cleanStackProgress {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(progress).font(.caption)
                            Spacer()
                            Button("Cancel") { model.cancelCleanStack() }
                        }
                    } else if status.needsCompletion {
                        Button("Finish clean stack") { model.finishCleanStack() }
                            .disabled(!model.canFinishCleanStack)
                            .help("Finish the original session's trail rejection. Keeps the saved master if cancelled or incomplete. Cancellation waits for the current processing step.")
                    } else {
                        Text("master.fit is complete. The on-screen image and replay are unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                if model.isRunning {
                    Button("End Session", role: .destructive) {
                        model.requestEndSession {
                            OBSRecordingWarning.confirm(title: "End session while OBS may be recording?", action: "End session; keep recording")
                        }
                    }
                        .disabled(model.importer.isGeneratingReplay)
                } else {
                    Button("Start Session") { model.startSession() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.importer.isImporting || model.isRestacking || model.liveSource.canCancelDetection)
                }
                Spacer()
                Text(model.sessionStateText)
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Go Live / End Broadcast — decoupled from session start.
            HStack {
                if model.isStorePreview {
                    Text(model.obsLocalRecording?.requiresAttention == true
                         ? "OBS may be recording — controls in Broadcast. End Session does not stop it."
                         : "OBS: connection check and local recording in Broadcast. Use OBS itself to stream.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
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
                ViewThatFits(in: .horizontal) {
                    HStack { outputShortcuts }
                    VStack(alignment: .leading, spacing: 8) { outputShortcuts }
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

    @ViewBuilder
    private var outputShortcuts: some View {
        Label("Session outputs", systemImage: "clock.arrow.circlepath")
            .font(.caption).foregroundStyle(.secondary)
        if hasSessionOutputs {
            Button("Folder") { openSessionFolder() }
                .disabled(model.lastSessionDirectory == nil)
                .help("Open the latest session folder.")
            Button("Master") { openMaster() }
                .disabled(latestMasterURL == nil)
                .help("Open master.fit in the default FITS app. External stacker sessions may not create one.")
            Button("Replay") { openReplay() }
                .disabled(model.replayURL == nil)
                .help("Open the latest replay video.")
        }
        Menu("More outputs") {
            Button("Open Sessions Folder") { openSessionsRoot() }
            Button("Regenerate Replay…") { pickSessionDirectory() }
                .disabled(model.importer.isGeneratingReplay)
            Button("Refresh Sizes") { refreshOutputFootprint() }
            Text("Output footprint: \(outputFootprintText)")
            if hasSessionOutputs {
                Divider()
                Button("Reveal Replay") { revealReplay() }.disabled(model.replayURL == nil)
                if latestImageURL != nil {
                    Button("Open Latest Image") { openLatestImage() }
                    Button("Reveal latest.png") { revealLatestImage() }
                }
                if latestMasterURL != nil {
                    Button("Reveal master.fit") { revealMaster() }
                }
                Divider()
                if sessionSummaryURL != nil { Button("Open Summary") { openSessionSummary() } }
                if frameSummaryURL != nil { Button("Open Frame CSV") { openFrameSummary() } }
                if subFramesURL != nil { Button("Open sub-frames.csv") { openSubFrames() } }
                Button("Copy Support Bundle") { copySupportBundle() }
                Button("Copy Summary") { copySessionSummary() }
            }
        }
        .fixedSize()
    }

    private func pickSessionDirectory() {
        let panel = model.makeDirectoryPanel(title: "Choose Session Directory",
                                             message: "Select a past session folder containing manifest.json")
        let liveAstro = model.liveAstroRoot
        if model.isStorePreview || FileManager.default.fileExists(atPath: liveAstro.path) {
            panel.directoryURL = liveAstro
        }
        if panel.runModal() == .OK, let url = panel.url {
            Task {
            guard let selected = await model.selectSourceFolder(url) else { return }
            model.importer.regenerateReplay(sessionDirectory: selected)
            }
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
        Task {
            do {
                let access = try await model.acquireOutputLocation()
                defer { withExtendedLifetime(access) {} }
                let session = model.lastSessionDirectory
                let counts = try await Task.detached { [access] in
                    defer { withExtendedLifetime(access) {} }
                    return (try DirectoryFootprint.byteCount(at: access.url),
                            try session.map { try DirectoryFootprint.byteCount(at: $0) })
                }.value
                let rootBytes = counts.0
                let rootSize = ByteCountFormatter.string(fromByteCount: rootBytes, countStyle: .file)
                if let sessionBytes = counts.1 {
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
    }

    private func openSessionFolder() {
        guard let url = model.lastSessionDirectory else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSessionsRoot() {
        Task {
            do {
                let access = try await model.acquireOutputLocation()
                defer { withExtendedLifetime(access) {} }
                let url = access.url
                try await Task.detached { [access] in
                    defer { withExtendedLifetime(access) {} }
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }.value
                NSWorkspace.shared.open(url)
                model.log.append("Opened sessions folder")
            } catch {
                model.errorMessage = "Could not open sessions folder: \(error.localizedDescription)"
            }
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
