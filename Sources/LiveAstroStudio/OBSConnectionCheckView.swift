import SwiftUI

/// Store-only inspection. Intentionally not the direct edition's OBSSection:
/// a successful check must not reveal controls that mutate the remote OBS state.
struct OBSConnectionCheckView: View {
    @Bindable var check: OBSConnectionCheck

    var body: some View {
        ScrollView {
            Form {
                Section("OBS connection — read only") {
                    Text("Open OBS yourself. In Tools → WebSocket Server Settings, enable the server and keep authentication enabled. Enter its connection details here.")
                        .foregroundStyle(.secondary)
                    TextField("Host", text: $check.host)
                        .help("Use 127.0.0.1 for OBS on this Mac. Remote connections use unencrypted WebSocket: use only a trusted network.")
                        .disabled(check.isChecking)
                    TextField("Port", text: $check.port)
                        .disabled(check.isChecking)
                    SecureField("WebSocket password", text: $check.password)
                        .disabled(check.isChecking)
                    Text("Entered manually, kept only until this app quits. LiveAstro does not read OBS's settings files or save this password.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Check connection and status") { check.start() }
                            .disabled(check.isChecking)
                        if check.isChecking {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { check.cancel() }
                        }
                    }
                    result
                }
                Section("What this preview can do") {
                    Text("This check only reads OBS status, then disconnects. It never starts or stops streaming or recording, changes scenes, or launches OBS.")
                    Text("You can still detach the Live display and capture it in OBS. Manage streaming and recording in OBS itself; ending a LiveAstro session does not control OBS in this preview.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .background(AlwaysVisibleScroller())
        }
        .scrollIndicators(.visible)
        .onDisappear { check.cancel() }
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
