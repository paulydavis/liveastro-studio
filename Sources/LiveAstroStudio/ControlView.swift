import SwiftUI
import AppKit

struct ControlView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Watch Folder") {
                HStack {
                    Text(model.watchFolder?.path ?? "none selected")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { pickFolder() }.disabled(model.isRunning)
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
            Section {
                HStack {
                    Button("Open Broadcast Window") { openWindow(id: "broadcast") }
                    Spacer()
                    if model.isRunning {
                        Button("End Session", role: .destructive) { model.endSession() }
                            .disabled(model.isGeneratingReplay)
                    } else {
                        Button("Start Session") { model.startSession() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if model.isGeneratingReplay { ProgressView("Rendering replay…") }
                if let url = model.replayURL {
                    Button("Reveal Replay in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Section("Log") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.suffix(200).enumerated()), id: \.offset) {
                            Text($0.element).font(.system(.caption, design: .monospaced))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .alert("LiveAstro", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { model.watchFolder = panel.url }
    }
}
