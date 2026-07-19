import SwiftUI
import LiveAstroCore
import UniformTypeIdentifiers

/// Native-mode "Calibration" setup: pick or build master dark/flat/bias-or-dark-flat.
/// Selections persist via CalibrationStore; masters build off the main thread.
struct CalibrationSection: View {
    @Binding var selection: CalibrationSelection
    var onLog: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            masterRow("Dark", fileStem: "dark", path: $selection.darkPath, kind: .dark, needsFlatOffset: false)
            masterRow("Flat", fileStem: "flat", path: $selection.flatPath, kind: .flat, needsFlatOffset: true)
            masterRow("Bias / Dark-flat", fileStem: "bias_dark_flat", path: $selection.biasPath,
                      kind: .bias, needsFlatOffset: false)
            Text("Bias / dark-flat is used to clean flats; it is not applied to lights directly.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func masterRow(_ label: String, fileStem: String, path: Binding<String?>,
                           kind: MasterKind, needsFlatOffset: Bool) -> some View {
        HStack {
            Text(label).frame(width: 104, alignment: .leading)
                .help(helpText(for: label))
            Text(path.wrappedValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                .foregroundStyle(path.wrappedValue == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Use file…") { pickFile(path) }
                .help("Point to a pre-built master \(label.lowercased()) FITS file.")
            Button("Build…") { pickFolderAndBuild(path, label: label, fileStem: fileStem,
                                                  kind: kind, needsFlatOffset: needsFlatOffset) }
                .help("Choose a folder of raw \(label.lowercased()) frames and build a master by mean-combining them.")
            if path.wrappedValue != nil { Button("Clear") { path.wrappedValue = nil } }
        }
    }

    private func helpText(for label: String) -> String {
        switch label {
        case "Dark":
            "Dark calibration master — subtracted from every light before stacking."
        case "Flat":
            "Flat calibration master — corrects dust and vignetting; cleaned by the selected bias / dark-flat when built."
        default:
            "Bias or dark-flat master — used to calibrate flats, not applied directly to lights."
        }
    }

    private func pickFile(_ path: Binding<String?>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fit") ?? .data,
                                     UTType(filenameExtension: "fits") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
    }

    private func pickFolderAndBuild(_ path: Binding<String?>, label: String, fileStem: String,
                                    kind: MasterKind, needsFlatOffset: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: nil))?
            .filter { ["fit", "fits"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path } ?? []
        let biasURL = needsFlatOffset ? selection.biasPath.map { URL(fileURLWithPath: $0) } : nil
        onLog("Building \(label.lowercased()) master from \(urls.count) frames…")
        DispatchQueue.global(qos: .userInitiated).async {
            let bias = biasURL.flatMap { try? MasterBuilder.load($0) }
            do {
                let master = try MasterBuilder.combine(fitsURLs: urls, kind: kind, bias: bias)
                let dir = CalibrationStore.mastersDirectory()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let out = dir.appendingPathComponent("master_\(fileStem).fit")
                try MasterBuilder.save(master, to: out)
                DispatchQueue.main.async { path.wrappedValue = out.path; onLog("Built \(out.lastPathComponent)") }
            } catch {
                DispatchQueue.main.async { onLog("Build failed: \(error)") }
            }
        }
    }
}
