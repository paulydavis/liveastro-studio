import SwiftUI
import AppKit
import LiveAstroCore

struct CaptureSettingsView: View {
    @Bindable var model: AppModel

    private var liveWorkflowDisabled: Bool {
        model.isRunning || model.importer.isImporting || model.liveSource.isDetecting
    }

    private var offlineWorkflowDisabled: Bool {
        model.isRunning || model.importer.isImporting
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Start Workflow") {
                    WorkflowActionRow(
                        title: "Live from Seestar",
                        subtitle: "Auto-detect the mounted Seestar folder, relay new subs, and start native live stacking.",
                        systemImage: "dot.radiowaves.left.and.right",
                        disabled: liveWorkflowDisabled
                    ) {
                        model.liveSource.startSeestarLive()
                    }

                    WorkflowActionRow(
                        title: "Live from ASIAIR",
                        subtitle: "Auto-detect the ASIAIR Autorun/Light folder and start native live stacking.",
                        systemImage: "camera.aperture",
                        disabled: liveWorkflowDisabled
                    ) {
                        model.liveSource.startASIAIRLive()
                    }

                    WorkflowActionRow(
                        title: "Live from Folder / NINA",
                        subtitle: "Watch any folder where NINA or another capture app writes new FITS light frames.",
                        systemImage: "folder.badge.plus",
                        disabled: liveWorkflowDisabled
                    ) {
                        pickNativeWatchFolderLive()
                    }

                    WorkflowActionRow(
                        title: "Watch Siril / External Stacker",
                        subtitle: "Watch a live_stack FITS output from Siril or another stacker instead of stacking raw subs.",
                        systemImage: "rectangle.stack.badge.play",
                        disabled: liveWorkflowDisabled
                    ) {
                        pickStackerOutputWatchFolder()
                    }

                    WorkflowActionRow(
                        title: "Stack Previous Shoot",
                        subtitle: "Choose a folder of existing FITS light frames and stack them offline.",
                        systemImage: "tray.and.arrow.down",
                        disabled: offlineWorkflowDisabled
                    ) {
                        pickImportFolder()
                    }

                    WorkflowActionRow(
                        title: "Try Demo",
                        subtitle: "Start a local sample stack stream so you can test the display, outputs, and replay without clear skies.",
                        systemImage: "sparkles",
                        disabled: liveWorkflowDisabled
                    ) {
                        model.startDemoSession()
                    }
                }
                Section("Watch Folder") {
                    Picker("Source", selection: $model.sourceMode) {
                        ForEach(AppModel.SourceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning || model.importer.isImporting)
                    .help("Seestar Live displays Siril's live_stack.fit directly; Raw subs stacks individual exposures natively using LiveAstro's built-in stacker.")

                    HStack {
                        Text(model.watchFolder?.path ?? "none selected")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { pickFolder() }
                            .disabled(model.isRunning || model.importer.isImporting)
                            .help("Choose the folder to watch for incoming FITS subs or the Seestar relay folder.")
                    }
                    TextField("File prefix (empty = any; e.g. Light_ for native subs)",
                              text: $model.fileNamePrefix)
                        .disabled(model.isRunning || model.importer.isImporting)
                        .help("Only process files whose name starts with this prefix; leave empty to accept all FITS files in the watch folder.")
                    helpToggle("Neutralize background (OSC white balance)", isOn: $model.neutralizeBackground,
                               help: "Apply a per-channel background neutralization pass after stacking to correct OSC white balance drift.")
                        .disabled(model.isRunning || model.importer.isImporting)
                    helpToggle("Reject outliers (σ-clip)", isOn: $model.rejectionEnabled,
                               help: "Drop satellite / plane / cosmic-ray streaks by clamping pixels that deviate from the per-pixel stack statistics (winsorized κ-σ). On by default.")
                        .disabled(model.isRunning || model.importer.isImporting)
                    helpToggle("Weight frames by quality", isOn: $model.frameWeightingEnabled,
                               help: "Give sharper, lower-noise subs more influence in the stack (star count + background noise). Turn off for an equal-weight stack.")
                        .disabled(model.isRunning || model.importer.isImporting)
                    helpToggle("Match sky background", isOn: $model.backgroundNormalizationEnabled,
                               help: "Level each sub's sky gradient to the reference before stacking, so a drifting light-pollution ramp or moonrise gradient doesn't leave a residual gradient the master can't remove. Low-order per channel; off for an unadjusted stack.")
                        .disabled(model.isRunning || model.importer.isImporting)
                    helpToggle("Match transparency", isOn: $model.scaleNormalizationEnabled,
                               help: "Scale each sub's signal to the reference brightness using matched star fluxes, so haze or thin cloud doesn't dim the master. Off for an unadjusted stack. Requires Match sky background (scaling pivots about the matched background).")
                        .disabled(model.isRunning || model.importer.isImporting)
                    HStack(spacing: 6) {
                        Text("Keep relay sessions")
                        InfoButton(text: "Live sessions stage incoming subs in ~/LiveAstro/relay. Sessions older than this are deleted automatically when a new session starts — they are copies; originals stay on the Seestar/rig. Off disables pruning.")
                        Spacer()
                        Picker("", selection: $model.liveSource.relayRetentionDays) {
                            Text("Off").tag(0)
                            Text("3d").tag(3)
                            Text("7d").tag(7)
                            Text("14d").tag(14)
                            Text("30d").tag(30)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 300)
                        .disabled(model.isRunning || model.importer.isImporting)
                    }
                    HStack(spacing: 6) {
                        Text("Debayer")
                        InfoButton(text: "Malvar (high quality) keeps star cores sharp and fringe-free (recommended). Bilinear is the legacy demosaic.")
                        Spacer()
                        Picker("", selection: $model.demosaic) {
                            Text("Bilinear").tag(DemosaicMethod.bilinear)
                            Text("Malvar (high quality)").tag(DemosaicMethod.malvar)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .disabled(model.isRunning || model.importer.isImporting)
                    }
                    if model.rejectionEnabled {
                        Picker("Strength", selection: $model.rejectionStrength) {
                            Text("Low").tag(RejectionStrength.low)
                            Text("Medium").tag(RejectionStrength.medium)
                            Text("High").tag(RejectionStrength.high)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isRunning || model.importer.isImporting)
                        .help("Higher = safer (rejects less); lower = more aggressive. Medium (κ=3) is the validated default.")
                    }
                    Picker("Post-process", selection: $model.processorBackend) {
                        Text("None").tag(ProcessorBackend.none)
                        Text("GraXpert").tag(ProcessorBackend.graxpert)
                        Text("Native NR").tag(ProcessorBackend.nativeDenoise)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning || model.importer.isImporting || model.importer.isProcessing)
                    .help("After stacking, optionally post-process the master to a master_processed FITS: GraXpert (background extraction + denoise, requires install) or the built-in Native NR denoiser.")
                }
                if model.sourceMode == .nativeStack {
                    Section("Calibration") {
                        CalibrationSection(model: model)
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
                Section("Session end") {
                    helpToggle("Idle safeguard — save master if capture stalls",
                               isOn: $model.idleSafeguardEnabled,
                               help: "Writes master.fit and keeps stacking; a cloud gap resumes normally.")
                        .disabled(model.sourceMode != .nativeStack)
                    if model.sourceMode != .nativeStack {
                        Text("Native stacking only — external stackers own their own master.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.idleSafeguardEnabled {
                        Stepper("After \(model.idleSafeguardMinutes) min idle",
                                value: $model.idleSafeguardMinutes, in: 5...120, step: 5)
                            .help("How long capture may stall before a master snapshot is written. Stacking continues; a resumed feed re-arms the safeguard.")
                            .disabled(model.sourceMode != .nativeStack)
                    }
                    helpToggle("Auto-stop at a set time", isOn: $model.plannedStopEnabled,
                               help: "Runs a full End Session at this time (writes master + replay, ends an owned broadcast). Does not quit the app.")
                    if model.plannedStopEnabled {
                        DatePicker("Stop at", selection: Binding(
                            get: { Calendar.current.date(bySettingHour: model.plannedStopHour,
                                    minute: model.plannedStopMinute, second: 0, of: Date()) ?? Date() },
                            set: { newDate in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                model.plannedStopHour = c.hour ?? 3
                                model.plannedStopMinute = c.minute ?? 0
                            }), displayedComponents: .hourAndMinute)
                            .help("Runs a full End Session at this clock time (next occurrence, crosses midnight).")
                    }
                }
            }
            .formStyle(.grouped)
            .background(AlwaysVisibleScroller())
        }
        .scrollIndicators(.visible)
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

    private func pickNativeWatchFolderLive() {
        pickWatchFolderLive(
            sourceMode: .nativeStack,
            title: "Choose Live FITS Folder",
            message: "Select the folder where NINA, ASIAIR, or another capture app writes new FITS light frames."
        )
    }

    private func pickStackerOutputWatchFolder() {
        pickWatchFolderLive(
            sourceMode: .stackerOutput,
            title: "Choose Stacker Output Folder",
            message: "Select the folder where Siril or another stacker writes live_stack FITS output."
        )
    }

    private func pickWatchFolderLive(sourceMode: AppModel.SourceMode,
                                     title: String,
                                     message: String) {
        let panel = makeDirectoryPanel(title: title, message: message)
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            model.sourceMode = sourceMode
            model.liveSource.startWatchFolderLive(source: url, sourceMode: sourceMode)
        }
    }

    private func pickImportFolder() {
        let panel = makeDirectoryPanel(title: "Choose Subs Folder",
                                       message: "Select a folder containing raw FITS subs to import")
        if panel.runModal() == .OK, let url = panel.url {
            model.importer.importSubs(from: url)
        }
    }
}
