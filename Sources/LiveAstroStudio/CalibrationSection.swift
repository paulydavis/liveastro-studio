import SwiftUI
import LiveAstroCore
import UniformTypeIdentifiers

/// Calibration setup: a reusable library of master darks/bias (auto-matched to the
/// session by camera + settings), plus per-session flats and optional dark-flats.
/// Master building/rebuilding runs off the main thread in AppModel.
struct CalibrationSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.calibrationStatus.isEmpty {
                Label(model.calibrationStatus, systemImage: statusIcon)
                    .font(.caption).foregroundStyle(.secondary)
            }

            // --- Darks / Bias library ---
            HStack {
                Text("Darks / Bias library").font(.caption.weight(.semibold))
                if model.calibrationBusy { ProgressView().controlSize(.small).padding(.leading, 2) }
                Spacer()
                Button("Add darks…") { addFolder(.dark) }.disabled(model.calibrationBusy)
                Button("Add bias…") { addFolder(.bias) }.disabled(model.calibrationBusy)
            }
            if model.libraryEntries.isEmpty {
                Text("No masters yet — add a folder of raw darks or bias frames. The camera, gain, exposure and temperature are read from the FITS headers.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(model.libraryEntries) { f in
                    HStack(spacing: 8) {
                        Image(systemName: f.kind == .dark ? "moon.fill" : "circle.dashed")
                            .foregroundStyle(.secondary).font(.caption)
                        Text(model.summary(of: f)).font(.caption)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Rebuild") { model.rebuildMaster(f.id) }
                            .buttonStyle(.borderless).font(.caption)
                            .disabled(model.calibrationBusy || f.sourcePath == nil)
                            .help("Re-combine this master from its source folder (e.g. after adding more frames).")
                        Button(role: .destructive) { model.removeMaster(f.id) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).font(.caption).disabled(model.calibrationBusy)
                    }
                }
            }
            Toggle("Scale darks across exposures (uses bias)", isOn: $model.scaleDarksAcrossExposures)
                .font(.caption)
                .help("When no exact-exposure dark is in the library, scale the nearest dark to the light's exposure using a matching bias.")

            Divider().padding(.vertical, 2)

            // --- Flats (this session) ---
            Text("Flats (this session)").font(.caption.weight(.semibold))
            folderRow("Flats", folder: $model.sessionFlatsFolder,
                      help: "A folder of raw flats shot for this session — ideally before the lights. Built into a master flat at Start.")
            folderRow("Dark-flats (optional)", folder: $model.sessionDarkFlatsFolder,
                      help: "Optional raw dark-flats — subtracted from the flats when the master flat is built.")
            Text("Flats aren't stored in the library — they're built fresh each session from the folders above.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { model.refreshLibraryEntries() }
    }

    private var statusIcon: String {
        model.calibrationStatus.contains("✓") ? "checkmark.seal.fill" : "exclamationmark.triangle"
    }

    @ViewBuilder
    private func folderRow(_ label: String, folder: Binding<URL?>, help: String) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 132, alignment: .leading).help(help)
            Text(folder.wrappedValue?.lastPathComponent ?? "None")
                .font(.caption)
                .foregroundStyle(folder.wrappedValue == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose…") { if let u = pickFolder() { folder.wrappedValue = u } }
            if folder.wrappedValue != nil { Button("Clear") { folder.wrappedValue = nil } }
        }
    }

    private func addFolder(_ kind: MasterKind) {
        if let u = pickFolder() { model.addMasterFromFolder(u, kind: kind) }
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
