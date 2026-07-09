import SwiftUI
import LiveAstroCore
import UniformTypeIdentifiers

/// Native-mode "Calibration" setup: pick or build master dark/flat/bias.
/// Selections persist via CalibrationStore; masters build off the main thread.
struct CalibrationSection: View {
    @Binding var selection: CalibrationSelection
    var onLog: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            masterRow("Dark", path: $selection.darkPath, kind: .dark, needsBias: false)
            masterRow("Flat", path: $selection.flatPath, kind: .flat, needsBias: true)
            masterRow("Bias", path: $selection.biasPath, kind: .bias, needsBias: false)
            Text("Bias is used to clean flats; it is not applied to lights directly.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func masterRow(_ label: String, path: Binding<String?>,
                           kind: MasterKind, needsBias: Bool) -> some View {
        HStack {
            Text(label).frame(width: 44, alignment: .leading)
                .help("\(label) calibration frame — applied to every light sub before stacking.")
            Text(path.wrappedValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                .foregroundStyle(path.wrappedValue == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Use file…") { pickFile(path) }
                .help("Point to a pre-built master \(label.lowercased()) FITS file.")
            Button("Build…") { pickFolderAndBuild(path, label: label, kind: kind, needsBias: needsBias) }
                .help("Choose a folder of raw \(label.lowercased()) frames and build a master by median-combining them.")
            if path.wrappedValue != nil { Button("Clear") { path.wrappedValue = nil } }
        }
    }

    private func pickFile(_ path: Binding<String?>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fit") ?? .data,
                                     UTType(filenameExtension: "fits") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
    }

    private func pickFolderAndBuild(_ path: Binding<String?>, label: String, kind: MasterKind, needsBias: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: nil))?
            .filter { ["fit", "fits"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path } ?? []
        let biasURL = needsBias ? selection.biasPath.map { URL(fileURLWithPath: $0) } : nil
        onLog("Building \(label.lowercased()) master from \(urls.count) frames…")
        DispatchQueue.global(qos: .userInitiated).async {
            let bias = biasURL.flatMap { try? MasterBuilder.load($0) }
            do {
                let master = try MasterBuilder.combine(fitsURLs: urls, kind: kind, bias: bias)
                let dir = CalibrationStore.mastersDirectory()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let out = dir.appendingPathComponent("master_\(label.lowercased()).fit")
                try MasterBuilder.save(master, to: out)
                DispatchQueue.main.async { path.wrappedValue = out.path; onLog("Built \(out.lastPathComponent)") }
            } catch {
                DispatchQueue.main.async { onLog("Build failed: \(error)") }
            }
        }
    }
}
