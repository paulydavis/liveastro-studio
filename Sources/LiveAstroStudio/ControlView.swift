import SwiftUI
import AppKit
import LiveAstroCore

struct ControlView: View {
    @Environment(AppModel.self) private var model

    private let logDisplayCap = 200
    private let logMinHeight: CGFloat = 120

    /// A Form toggle row with a visible ⓘ info button next to the label. macOS `Form`
    /// only attaches `.help()` tooltips to the switch control, not the label text, so
    /// hovering the label showed nothing. A tap-to-reveal info button is an explicit,
    /// discoverable affordance that doesn't depend on hover tracking.
    private func helpToggle(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(text: help)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
    }

    /// Small ⓘ affordance that reveals its help text in a popover on tap (and, as a
    /// bonus, a tooltip on hover — `.help()` works reliably on a Button control).
    private struct InfoButton: View {
        let text: String
        @State private var showing = false
        var body: some View {
            Button { showing.toggle() } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(text)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 300)
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    Section("Watch Folder") {
                        Picker("Source", selection: $model.sourceMode) {
                            ForEach(AppModel.SourceMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isRunning || model.isImporting)
                        .help("Seestar Live displays Siril's live_stack.fit directly; Raw subs stacks individual exposures natively using LiveAstro's built-in stacker.")

                        HStack {
                            Text(model.watchFolder?.path ?? "none selected")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { pickFolder() }
                                .disabled(model.isRunning || model.isImporting)
                                .help("Choose the folder to watch for incoming FITS subs or the Seestar relay folder.")
                        }
                        TextField("File prefix (empty = any; e.g. Light_ for native subs)",
                                  text: $model.fileNamePrefix)
                            .disabled(model.isRunning || model.isImporting)
                            .help("Only process files whose name starts with this prefix; leave empty to accept all FITS files in the watch folder.")
                        helpToggle("Neutralize background (OSC white balance)", isOn: $model.neutralizeBackground,
                                   help: "Apply a per-channel background neutralization pass after stacking to correct OSC white balance drift.")
                            .disabled(model.isRunning || model.isImporting)
                        helpToggle("Reject outliers (σ-clip)", isOn: $model.rejectionEnabled,
                                   help: "Drop satellite / plane / cosmic-ray streaks by clamping pixels that deviate from the per-pixel stack statistics (winsorized κ-σ). On by default.")
                            .disabled(model.isRunning || model.isImporting)
                        helpToggle("Weight frames by quality", isOn: $model.frameWeightingEnabled,
                                   help: "Give sharper, lower-noise subs more influence in the stack (star count + background noise). Turn off for an equal-weight stack.")
                            .disabled(model.isRunning || model.isImporting)
                        helpToggle("Match sky background", isOn: $model.backgroundNormalizationEnabled,
                                   help: "Level each sub's sky gradient to the reference before stacking, so a drifting light-pollution ramp or moonrise gradient doesn't leave a residual gradient the master can't remove. Low-order per channel; off for an unadjusted stack.")
                            .disabled(model.isRunning || model.isImporting)
                        helpToggle("Match transparency", isOn: $model.scaleNormalizationEnabled,
                                   help: "Scale each sub's signal to the reference brightness using matched star fluxes, so haze or thin cloud doesn't dim the master. Off for an unadjusted stack. Requires Match sky background (scaling pivots about the matched background).")
                            .disabled(model.isRunning || model.isImporting)
                        HStack(spacing: 6) {
                            Text("Keep relay sessions")
                            InfoButton(text: "Live sessions stage incoming subs in ~/LiveAstro/relay. Sessions older than this are deleted automatically when a new session starts — they are copies; originals stay on the Seestar/rig. Off disables pruning.")
                            Spacer()
                            Picker("", selection: $model.relayRetentionDays) {
                                Text("Off").tag(0)
                                Text("3d").tag(3)
                                Text("7d").tag(7)
                                Text("14d").tag(14)
                                Text("30d").tag(30)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 300)
                            .disabled(model.isRunning || model.isImporting)
                        }
                        HStack(spacing: 6) {
                            Text("Debayer")
                            InfoButton(text: "RCD keeps star cores sharp and fringe-free (recommended). Bilinear is the legacy demosaic.")
                            Spacer()
                            Picker("", selection: $model.demosaic) {
                                Text("Bilinear").tag(DemosaicMethod.bilinear)
                                Text("RCD").tag(DemosaicMethod.rcd)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 220)
                            .disabled(model.isRunning || model.isImporting)
                        }
                        if model.rejectionEnabled {
                            Picker("Strength", selection: $model.rejectionStrength) {
                                Text("Low").tag(RejectionStrength.low)
                                Text("Medium").tag(RejectionStrength.medium)
                                Text("High").tag(RejectionStrength.high)
                            }
                            .pickerStyle(.segmented)
                            .disabled(model.isRunning || model.isImporting)
                            .help("Higher = safer (rejects less); lower = more aggressive. Medium (κ=3) is the validated default.")
                        }
                        Picker("Post-process", selection: $model.processorBackend) {
                            Text("None").tag(ProcessorBackend.none)
                            Text("GraXpert").tag(ProcessorBackend.graxpert)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isRunning || model.isImporting || model.isProcessing)
                        .help("After stacking, optionally run GraXpert (background extraction + denoise) to write master_processed.fit next to the raw master. Requires GraXpert installed.")
                    }
                    if model.sourceMode == .nativeStack {
                        Section("Calibration") {
                            CalibrationSection(selection: $model.calibration,
                                               onLog: { model.log.append($0) })
                        }
                    }
                    Section("Session Profile") {
                        TextField("Target name", text: $model.targetName)
                        TextField("Telescope", text: $model.telescope)
                        TextField("Camera", text: $model.camera)
                        TextField("Mount", text: $model.mount)
                        TextField("Filter", text: $model.filter)
                        TextField("Location", text: $model.locationLabel)
                        TextField("Bortle (1–9)", text: $model.bortleText)
                        TextField("Sub-exposure seconds", text: $model.subExposureText)
                            .help("Individual sub-exposure length in seconds; recorded in the session manifest and used for dark-frame matching.")
                        TextField("Notes", text: $model.notes)
                    }
                    // Observes the OBSController (Combine ObservableObject) so its
                    // @Published state/scene/record changes re-render this section.
                    OBSSection(model: model)
                    Section("Display Adjustments") {
                        VStack(alignment: .leading) {
                            Text("Black point")
                            Slider(value: $model.displayAdjustments.blackPoint, in: 0...0.2) { editing in
                                if !editing { model.applyDisplayAdjustments() }
                            }
                            .help("Darken the sky background. 0 = auto.")
                        }
                        VStack(alignment: .leading) {
                            Text("Stretch strength")
                            Slider(value: $model.displayAdjustments.midtoneStrength, in: -1...1) { editing in
                                if !editing { model.applyDisplayAdjustments() }
                            }
                            .help("How aggressive the stretch is. 0 = auto.")
                        }
                        VStack(alignment: .leading) {
                            Text("Saturation")
                            Slider(value: $model.displayAdjustments.saturation, in: 0...2) { editing in
                                if !editing { model.applyDisplayAdjustments() }
                            }
                            .help("Color intensity. 1 = unchanged.")
                        }
                        helpToggle("Flatten background (DBE)", isOn: $model.displayAdjustments.backgroundExtraction,
                                   help: "Remove the light-pollution gradient so the sky darkens evenly. Off by default.")
                            .onChange(of: model.displayAdjustments.backgroundExtraction) { _, _ in
                                model.applyDisplayAdjustments()
                            }
                        if model.displayAdjustments.backgroundExtraction {
                            HStack {
                                Text("Scale").frame(width: 90, alignment: .leading)
                                Slider(value: $model.displayAdjustments.bgScale, in: 1...15) { editing in
                                    if !editing { model.applyDisplayAdjustments() }
                                }
                                Text(String(format: "%.1f%%", model.displayAdjustments.bgScale))
                                    .frame(width: 48, alignment: .trailing).monospacedDigit()
                            }
                            .help("Smoothing scale as % of image size — lower follows local/corner gradients, higher removes only broad gradients.")
                            HStack {
                                Text("Smoothest").frame(width: 90, alignment: .leading)
                                Slider(value: $model.displayAdjustments.bgSmoothest, in: 0...3) { editing in
                                    if !editing { model.applyDisplayAdjustments() }
                                }
                                Text(String(format: "%.1f", model.displayAdjustments.bgSmoothest))
                                    .frame(width: 48, alignment: .trailing).monospacedDigit()
                            }
                            .help("Extra blur on the background model — raise to remove residual blotchiness, lower to track non-smooth gradients.")
                        }
                        Button("Reset") {
                            model.displayAdjustments = .neutral
                            model.applyDisplayAdjustments()
                        }
                        .help("Back to the neutral auto-stretch look.")
                    }
                    Section("Log") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(model.log.suffix(logDisplayCap).enumerated()), id: \.offset) {
                                    Text($0.element).font(.system(.caption, design: .monospaced))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: logMinHeight)
                    }
                }
                .formStyle(.grouped)
            }

            Divider()

            // Fixed footer — always visible regardless of scroll position.
            VStack(spacing: 8) {
                HStack {
                    if model.isRunning {
                        Button("End Session", role: .destructive) { model.endSession() }
                            .disabled(model.isGeneratingReplay)
                    } else {
                        Button("Start Session") { model.startSession() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isImporting)
                    }
                    Spacer()
                    Button {
                        model.startSeestarLive()
                    } label: { Label("Start Seestar", systemImage: "dot.radiowaves.left.and.right") }
                    .help("Auto-detect the mounted Seestar folder, start relaying its 10s subs, and begin native stacking — one tap.")
                    .disabled(model.isRunning || model.isImporting || model.isDetecting)
                    Button {
                        model.startASIAIRLive()
                    } label: { Label("Start ASIAIR", systemImage: "camera.aperture") }
                    .help("Auto-detect the ASIAIR's Autorun/Light folder, relay its subs, and begin native stacking — one tap.")
                    .disabled(model.isRunning || model.isImporting || model.isDetecting)
                    Button("Choose Folder…") { pickWatchFolderLive() }
                        .help("Live-stack subs from any folder your rig writes to (NINA / ASI camera / any incoming-subs folder) — session-scoped from the moment you start.")
                        .disabled(model.isRunning || model.isImporting || model.isDetecting)
                    Button("Import Subs…") { pickImportFolder() }
                        .disabled(model.isRunning || model.isImporting)
                        .help("Select a folder of previously captured FITS subs to stack offline, with progress tracking and Cancel support.")
                }
                // Go Live / End Broadcast — decoupled from session start.
                HStack {
                    switch model.broadcast.broadcastState {
                    case .idle:
                        Button("Go Live") { model.broadcast.goLive() }
                            .help("Broadcast the live stack to YouTube via OBS (configure the YouTube key in OBS ▸ Settings ▸ Stream first).")
                    case .connecting:
                        HStack { ProgressView().controlSize(.small); Text("Connecting OBS…") }
                    case .live:
                        HStack(spacing: 10) {
                            Button("End Broadcast", role: .destructive) { model.broadcast.endBroadcast() }
                            if let h = model.broadcast.streamHealth {
                                Text("● LIVE · \(formatDuration(h.durationSeconds)) · \(h.skippedFrames) dropped · \(Int((h.congestion * 100).rounded()))% cong")
                                    .foregroundStyle(.red).font(.caption)
                            }
                        }
                    case .stopping:
                        HStack { ProgressView().controlSize(.small); Text("Stopping…") }
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
                if model.isImporting {
                    VStack(spacing: 4) {
                        ProgressView(value: Double(model.importProcessed),
                                     total: Double(max(model.importTotal, 1)))
                        HStack {
                            Text("\(model.importProcessed) / \(model.importTotal)")
                            Spacer()
                            Text("✓ \(model.acceptedCount)  ✗ \(model.rejectedCount)").foregroundStyle(.secondary)
                            Button("Cancel", role: .cancel) { model.cancelImport() }
                        }.font(.caption)
                    }.padding(.horizontal)
                }
                if !model.isRunning {
                    HStack {
                        Button("Regenerate Replay…") { pickSessionDirectory() }
                            .disabled(model.isGeneratingReplay)
                        if let url = model.replayURL {
                            Spacer()
                            Button("Reveal Replay in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                }
                if model.processorBackend == .graxpert, model.sourceMode == .nativeStack, let dir = model.lastSessionDirectory {
                    Button(model.isProcessing ? "Processing…" : "Process master") {
                        model.processMaster(sessionDirectory: dir)
                    }
                    .disabled(model.isProcessing || GraXpertProcessor.defaultExecutable() == nil)
                    .help(GraXpertProcessor.defaultExecutable() == nil
                          ? "GraXpert not found — install from graxpert.com"
                          : "Run GraXpert on the last stacked master → master_processed.fit")
                }
                if model.isGeneratingReplay { ProgressView("Rendering replay…") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .alert("LiveAstro", isPresented: $model.isShowingError) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    private func makeDirectoryPanel(title: String? = nil, message: String? = nil) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let title { panel.title = title }
        if let message { panel.message = message }
        return panel
    }

    private func pickFolder() {
        let panel = makeDirectoryPanel()
        if panel.runModal() == .OK { model.watchFolder = panel.url }
    }

    private func pickWatchFolderLive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            model.startWatchFolderLive(source: url)
        }
    }

    private func pickImportFolder() {
        let panel = makeDirectoryPanel(title: "Choose Subs Folder",
                                       message: "Select a folder containing raw FITS subs to import")
        if panel.runModal() == .OK, let url = panel.url {
            model.importSubs(from: url)
        }
    }

    private func pickSessionDirectory() {
        let panel = makeDirectoryPanel(title: "Choose Session Directory",
                                       message: "Select a past session folder containing manifest.json")
        let liveAstro = model.liveAstroRoot
        if FileManager.default.fileExists(atPath: liveAstro.path) {
            panel.directoryURL = liveAstro
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.regenerateReplay(sessionDirectory: url)
        }
    }
}

/// OBS controls, split out so it can `@ObservedObject` the controller.
///
/// `OBSController` is a Combine `ObservableObject` (not `@Observable`), held as a
/// plain `let` on the `@Observable` AppModel — so its `@Published` state/scene/
/// record changes would NOT drive a re-render if we only read them through the
/// model. Observing it directly here restores reactivity. Config fields
/// (host/port/password/toggles) are `@Observable` AppModel props, bound via
/// `@Bindable`.
private struct OBSSection: View {
    @Bindable var model: AppModel
    @ObservedObject private var obs: OBSController

    init(model: AppModel) {
        self.model = model
        self.obs = model.broadcast.obs
    }

    /// True once the controller is connected (any non-disconnected state).
    private var connected: Bool { obs.state != .disconnected }

    /// Short human label + status dot color for the current OBS state.
    private var status: (text: String, color: Color) {
        switch obs.state {
        case .disconnected: return ("disconnected", .secondary)
        case .connecting:   return ("connecting…", .orange)
        case .connected:    return ("connected", .green)
        case .streaming:    return ("streaming", .green)
        }
    }

    /// Two-way binding for the program-scene Picker: reads OBS's current program
    /// scene, writes go through `setScene` (operator override).
    private var sceneSelection: Binding<String?> {
        Binding(
            get: { obs.currentScene },
            set: { newValue in
                guard let name = newValue else { return }
                Task { await obs.setScene(name) }
            }
        )
    }

    var body: some View {
        Section("OBS") {
            // Status line: ● state text, plus a REC dot when recording.
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(status.color)
                Text(status.text)
                    .font(.system(.caption, design: .monospaced))
                if obs.isRecording {
                    Spacer()
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    Text("REC").font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                }
                Spacer()
                if connected {
                    Button("Disconnect") { obs.disconnect() }
                } else {
                    Button("Connect") { connectOBS() }
                }
            }

            // Connection config — locked while connected.
            TextField("Host", text: $model.broadcast.obsHost)
                .disabled(connected)
                .help("Hostname or IP address of the machine running OBS (use 127.0.0.1 when OBS is on the same Mac).")
            TextField("Port", value: $model.broadcast.obsPort, format: .number.grouping(.never))
                .disabled(connected)
                .help("OBS WebSocket server port — default is 4455; change only if you customised it in OBS → Tools → WebSocket Server Settings.")
            SecureField("Password (empty if auth off)", text: $model.broadcast.obsPassword)
                .disabled(connected)
                .help("OBS WebSocket password — copy it from OBS → Tools → WebSocket Server Settings → Show Connect Info (it regenerates each time OBS restarts with auto-generate on).")
            Toggle("Auto-launch OBS on session start", isOn: $model.broadcast.obsAutoLaunch)

            // Scene selection, fed by the controller's live scene list.
            HStack {
                Picker("Scene", selection: sceneSelection) {
                    Text("—").tag(String?.none)
                    ForEach(obs.sceneNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                Button {
                    Task { await obs.refreshScenes() }
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh scene list")
                .disabled(!connected)
            }

            Toggle("Record while streaming", isOn: $model.broadcast.obsRecord)

            // Scene automation: switch to the scope scene on a stall, back to the
            // stack scene on resume.
            Toggle("Scene automation (scope on stall)", isOn: $model.broadcast.sceneAutomationOn)
            Picker("Stack scene", selection: $model.broadcast.stackSceneName) {
                Text("—").tag("")
                ForEach(obs.sceneNames, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!model.broadcast.sceneAutomationOn)
            Picker("Scope scene", selection: $model.broadcast.scopeSceneName) {
                Text("—").tag("")
                ForEach(obs.sceneNames, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!model.broadcast.sceneAutomationOn)
        }
    }

    /// Connect using the form's host/port/password and refresh the scene list.
    private func connectOBS() {
        Task {
            let ok = await obs.connect(
                host: model.broadcast.obsHost, port: model.broadcast.obsPort,
                password: model.broadcast.obsPassword.isEmpty ? nil : model.broadcast.obsPassword)
            if ok { await obs.refreshScenes() }
        }
    }
}
