import SwiftUI
import AppKit
import LiveAstroCore

struct ControlView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private let logDisplayCap = 200
    private let logMinHeight: CGFloat = 120

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

                        HStack {
                            Text(model.watchFolder?.path ?? "none selected")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { pickFolder() }
                                .disabled(model.isRunning || model.isImporting)
                        }
                        TextField("File prefix (empty = any; e.g. Light_ for native subs)",
                                  text: $model.fileNamePrefix)
                            .disabled(model.isRunning || model.isImporting)
                        Toggle("Neutralize background (OSC white balance)", isOn: $model.neutralizeBackground)
                            .disabled(model.isRunning || model.isImporting)
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
                        TextField("Notes", text: $model.notes)
                    }
                    // Observes the OBSController (Combine ObservableObject) so its
                    // @Published state/scene/record changes re-render this section.
                    OBSSection(model: model)
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
                    Button("Import Subs…") { pickImportFolder() }
                        .disabled(model.isRunning || model.isImporting)
                }
                if model.isRunning && model.sourceMode == .nativeStack {
                    HStack {
                        Text("accepted \(model.acceptedCount) · rejected \(model.rejectedCount)")
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button("Reseed Reference") { model.reseedReference() }
                    }
                }
                if model.isImporting { ProgressView("Importing subs…") }
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
                if model.isGeneratingReplay { ProgressView("Rendering replay…") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .alert("LiveAstro", isPresented: $model.isShowingError) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
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
        self.obs = model.obs
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
            TextField("Host", text: $model.obsHost)
                .disabled(connected)
            TextField("Port", value: $model.obsPort, format: .number.grouping(.never))
                .disabled(connected)
            SecureField("Password (empty if auth off)", text: $model.obsPassword)
                .disabled(connected)
            Toggle("Auto-launch OBS on session start", isOn: $model.obsAutoLaunch)

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

            Toggle("Record while streaming", isOn: $model.obsRecord)

            // Scene automation: switch to the scope scene on a stall, back to the
            // stack scene on resume.
            Toggle("Scene automation (scope on stall)", isOn: $model.sceneAutomationOn)
            Picker("Stack scene", selection: $model.stackSceneName) {
                Text("—").tag("")
                ForEach(obs.sceneNames, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!model.sceneAutomationOn)
            Picker("Scope scene", selection: $model.scopeSceneName) {
                Text("—").tag("")
                ForEach(obs.sceneNames, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!model.sceneAutomationOn)
        }
    }

    /// Connect using the form's host/port/password and refresh the scene list.
    private func connectOBS() {
        Task {
            let ok = await obs.connect(
                host: model.obsHost, port: model.obsPort,
                password: model.obsPassword.isEmpty ? nil : model.obsPassword)
            if ok { await obs.refreshScenes() }
        }
    }
}
