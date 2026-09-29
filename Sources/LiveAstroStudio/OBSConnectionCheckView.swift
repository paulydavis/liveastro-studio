import SwiftUI

/// Store-only controls. The connection check stays read-only; local recording
/// has a separate controller and explicit start/stop, unrelated to session End.
struct OBSConnectionCheckView: View {
    @Bindable var check: OBSConnectionCheck
    @Bindable var recording: OBSLocalRecording
    @State private var showRecordingConsent = false

    var body: some View {
        ScrollView {
            Form {
                Section("OBS connection — read only") {
                    Text("Open OBS yourself. In Tools → WebSocket Server Settings, enable the server and keep authentication enabled. Enter its connection details here.")
                        .foregroundStyle(.secondary)
                    TextField("Host", text: $check.host)
                        .help("Use 127.0.0.1 for OBS on this Mac. Remote connections use unencrypted WebSocket: use only a trusted network.")
                        .disabled(check.isChecking || recording.requiresAttention)
                    TextField("Port", text: $check.port)
                        .disabled(check.isChecking || recording.requiresAttention)
                    SecureField("WebSocket password", text: $check.password)
                        .disabled(check.isChecking || recording.isBusy || recording.state == .recording)
                    Text("Entered manually, kept only until this app quits. LiveAstro does not read OBS's settings files or save this password.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Check connection and status") { check.start() }
                            .disabled(check.isChecking || recording.requiresAttention)
                        if check.isChecking {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { check.cancel() }
                        }
                    }
                    result
                }
                Section("Local recording in OBS") {
                    Text("Records OBS's current scene and audio to OBS's recording folder—not necessarily the LiveAstro image. Check the OBS preview first.")
                    HStack {
                        Button("Start local recording…") { showRecordingConsent = true }
                            .disabled(check.isChecking || recording.requiresAttention || check.endpointURL == nil)
                        Button("Stop recording") { recording.stop() }
                            .disabled(recording.state != .recording)
                        if recording.isBusy { ProgressView().controlSize(.small) }
                    }
                    recordingResult
                    Text("Start and stop recording here while this connection is active. Don't operate recording from another OBS controller at the same time: OBS cannot identify which recording belongs to an app. Ending a session or quitting LiveAstro does not stop recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("What this preview can do") {
                    Text("The connection check only reads status, then disconnects. Local recording uses the separate buttons above. Neither feature starts or stops public streaming, changes scenes, or launches OBS.")
                    Text("You can detach the Live display and capture it in OBS. Set up its scene and manage public streaming in OBS itself.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .background(AlwaysVisibleScroller())
        }
        .scrollIndicators(.visible)
        .onDisappear { check.cancel() }
        .alert("Start a local OBS recording?", isPresented: $showRecordingConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Start recording") {
                recording.start(endpoint: check.endpointURL, password: check.password)
            }
        } message: {
            Text("This records the picture and sound currently selected in OBS. Confirm its preview is what you intend. No public stream will be started. Use Stop recording here when finished.")
        }
    }

    @ViewBuilder private var recordingResult: some View {
        switch recording.state {
        case .idle: Text("No recording controlled by LiveAstro.").foregroundStyle(.secondary)
        case .starting: Text("Starting recording and waiting for OBS confirmation…")
        case .recording:
            Label("Recording started here — use Stop recording when finished", systemImage: "record.circle")
                .foregroundStyle(.red)
        case .stopping: Text("Stopping recording and waiting for OBS confirmation…")
        case .checking: Text("Checking whether OBS recording has stopped. No control commands sent.")
        case .finished(let path):
            Text("OBS confirmed recording stopped. Reported file: \(path)").textSelection(.enabled)
            Text("Open it in OBS's recording folder to check picture and sound.").font(.caption)
        case .failed(let message), .refused(let message): Text(message).foregroundStyle(.orange)
        case .uncertain(let message):
            Text(message).foregroundStyle(.orange)
            Button("Check that recording is stopped") {
                recording.checkStopped(endpoint: check.endpointURL, password: check.password)
            }
        }
    }

    @ViewBuilder private var result: some View {
        switch check.state {
        case .idle:
            Text("Not checked.").foregroundStyle(.secondary)
        case .checking:
            Text("Checking OBS… No output changes will be made.")
        case .cancelled:
            Text("Check cancelled. OBS output status is unknown.").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.orange)
        case .checked(let snapshot):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connection check passed — disconnected", systemImage: "checkmark.circle")
                Text("\(snapshot.endpoint) · Checked \(snapshot.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Streaming: \(snapshot.streaming ? "active" : "inactive") · Recording: \(snapshot.recording ? "active" : "inactive")")
                Text("Status at the time of the check, not live monitoring. Check again to refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
