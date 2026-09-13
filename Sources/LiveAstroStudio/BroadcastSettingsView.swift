import SwiftUI
import Combine
import LiveAstroCore

struct BroadcastSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            Form {
                // Observes the OBSController (Combine ObservableObject) so its
                // @Published state/scene/record changes re-render this section.
                OBSSection(model: model)
            }
            .formStyle(.grouped)
            .background(AlwaysVisibleScroller())
        }
        .scrollIndicators(.visible)
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

    /// Human label for a pre-flight chain link (Task 6 status panel).
    private func label(for link: PreflightLink) -> String {
        switch link {
        case .obsRunning:    return "OBS running"
        case .connected:     return "Connected"
        case .sceneCapture:  return "Stack scene capture"
        case .streamService: return "Stream service"
        case .streaming:     return "Streaming"
        }
    }

    var body: some View {
        Section("OBS") {
            // Go Live pre-flight chain (T5 state, T6 render): dumbly reflects
            // model.broadcast.preflight in chain order — no logic here.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(PreflightLink.chainOrder, id: \.self) { link in
                    let status = model.broadcast.preflight[link]
                    HStack(spacing: 6) {
                        switch status {
                        case .unknown:  Image(systemName: "circle").foregroundStyle(.secondary)
                        case .checking: ProgressView().controlSize(.mini)
                        case .ok:       Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed:   Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                        Text(label(for: link))
                        if case .failed(let reason, let remedy) = status {
                            Text("— \(reason). \(remedy)")
                                .font(.caption).foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding(.vertical, 4)

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
                    // Route through BroadcastController so a disconnect that strands a
                    // live stream lands in .stopUnconfirmed (honest state), never .idle.
                    // Disconnect ≠ stop, by design: no StopStream is sent.
                    Button("Disconnect") { model.broadcast.disconnect() }
                } else {
                    // Synchronous entry (review8 item 2): .connecting is reserved AT
                    // the click, so Go Live can't race the connect await — and after
                    // the link comes up the controller RECONCILES broadcastState with
                    // OBS's actual stream/record state (review7: an already-streaming
                    // OBS is adopted, never offered a double-starting Go Live).
                    // Cold-review1 finding 2: the enable-state mirrors the
                    // controller's entry guard — Connect is only legal when no
                    // broadcast machinery owns the session (the guard also no-ops
                    // defensively, so a stale render can't slip a reconnect in).
                    Button("Connect") { model.broadcast.beginConnectAndReconcile() }
                        .disabled(!model.broadcast.connectAllowed)
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
                .help("Auto-filled from OBS's local settings when left empty; paste manually only for remote OBS.")
            Toggle("Auto-launch OBS on Go Live", isOn: $model.broadcast.obsAutoLaunch)
                .help("When OBS is unreachable at Go Live, launch it in the background and retry the connection for up to 20 seconds. Session start and manual Connect never launch OBS.")

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

}
