import SwiftUI

struct DisplaySettingsView: View {
    @Bindable var model: AppModel

    @State private var windowHeight: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            previewPanel
                .padding(.horizontal).padding(.top)
            Divider().padding(.top, 8)
            ScrollView {
                Form {
                    Section("Night vision") {
                        helpToggle("Red screen", isOn: $model.nightVisionOn,
                                   help: "Tints the whole Mac display red to protect your dark adaptation at the scope — affects every app, not just LiveAstro. Clears when you quit.")
                            .onChange(of: model.nightVisionOn) { _, _ in model.applyNightVision() }
                        if model.nightVisionOn {
                            HStack {
                                Text("Brightness").frame(width: 90, alignment: .leading)
                                Slider(value: $model.nightVisionLevel, in: 1...100)
                                    .onChange(of: model.nightVisionLevel) { _, _ in
                                        if model.nightVisionOn { model.applyNightVision() }
                                    }
                                Text("\(Int(model.nightVisionLevel))%")
                                    .frame(width: 48, alignment: .trailing).monospacedDigit()
                            }
                            .help("Lower = dimmer and deeper red. Your keyboard brightness keys still work on top.")
                        }
                        Text("A screenshot still looks normal — macOS captures the image before the display tint is applied.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Section("Display Adjustments") {
                        VStack(alignment: .leading) {
                            Text("Black point")
                            Slider(value: $model.staged.pending.blackPoint, in: 0...0.2)
                                .onChange(of: model.staged.pending.blackPoint) { _, _ in
                                    model.refreshPreview()
                                }
                                .help("Darken the sky background. 0 = auto.")
                        }
                        VStack(alignment: .leading) {
                            Text("Stretch strength")
                            Slider(value: $model.staged.pending.midtoneStrength, in: -1...1)
                                .onChange(of: model.staged.pending.midtoneStrength) { _, _ in
                                    model.refreshPreview()
                                }
                                .help("How aggressive the stretch is. 0 = auto.")
                        }
                        VStack(alignment: .leading) {
                            Text("Saturation")
                            Slider(value: $model.staged.pending.saturation, in: 0...2)
                                .onChange(of: model.staged.pending.saturation) { _, _ in
                                    model.refreshPreview()
                                }
                                .help("Color intensity. 1 = unchanged.")
                        }
                        helpToggle("Flatten background (DBE)", isOn: $model.staged.pending.backgroundExtraction,
                                   help: "Remove the light-pollution gradient so the sky darkens evenly. Off by default.")
                            .onChange(of: model.staged.pending.backgroundExtraction) { _, _ in
                                model.refreshPreview(force: true)
                            }
                        if model.staged.pending.backgroundExtraction {
                            HStack {
                                Text("Scale").frame(width: 90, alignment: .leading)
                                Slider(value: $model.staged.pending.bgScale, in: 1...15)
                                    .onChange(of: model.staged.pending.bgScale) { _, _ in
                                        model.refreshPreview()
                                    }
                                Text(String(format: "%.1f%%", model.staged.pending.bgScale))
                                    .frame(width: 48, alignment: .trailing).monospacedDigit()
                            }
                            .help("Smoothing scale as % of image size — lower follows local/corner gradients, higher removes only broad gradients.")
                            HStack {
                                Text("Smoothest").frame(width: 90, alignment: .leading)
                                Slider(value: $model.staged.pending.bgSmoothest, in: 0...3)
                                    .onChange(of: model.staged.pending.bgSmoothest) { _, _ in
                                        model.refreshPreview()
                                    }
                                Text(String(format: "%.1f", model.staged.pending.bgSmoothest))
                                    .frame(width: 48, alignment: .trailing).monospacedDigit()
                            }
                            .help("Extra blur on the background model — raise to remove residual blotchiness, lower to track non-smooth gradients.")
                        }
                        VStack(alignment: .leading) {
                            Text("Denoise")
                            Slider(value: $model.staged.pending.denoiseStrength, in: 0...1)
                                .onChange(of: model.staged.pending.denoiseStrength) { _, _ in
                                    model.refreshPreview()
                                }
                                .help("Classic noise reduction — smooths background grain and color mottle on the displayed stack. 0 = off. master.fit is never modified.")
                        }
                        switch model.catalogState {
                        case .installed:
                            helpToggle("North up", isOn: $model.staged.pending.northUp,
                                       help: "Rotate the view so celestial north is up (display only — master.fit stays native). Needs a plate solve; enabled once the reference frame is solved.")
                                .onChange(of: model.staged.pending.northUp) { _, _ in
                                    model.refreshPreview(force: true)
                                }
                                .disabled(!model.solveAvailable)
                        case .notInstalled:
                            Button("Download star catalog (~32 MB) — enables North up") {
                                model.downloadCatalog()
                            }
                            .help("Downloads the Gaia bright-star catalog used to plate-solve and orient the view north-up. One-time, cached locally.")
                        case .downloading(let p):
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Downloading star catalog…").font(.caption)
                                ProgressView(value: p)
                            }
                        case .failed(let msg):
                            VStack(alignment: .leading, spacing: 2) {
                                Text(msg).font(.caption).foregroundStyle(.red)
                                Button("Retry download") { model.downloadCatalog() }
                            }
                        }
                        Text("Star catalog: Gaia DR3 (ESA/DPAC)")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Reset") {
                            model.resetAdjustments()
                        }
                        .help("Back to the recommended look (auto-stretch with background flattening on).")
                    }
                }
                .formStyle(.grouped)
                .background(AlwaysVisibleScroller())
            }
            .scrollIndicators(.visible)
        }
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { windowHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in windowHeight = h }
            }
        )
    }

    /// Preview occupies a share of the window, floored so it stays useful in a small window and
    /// capped so the controls beneath it never get squeezed out.
    private var panelHeight: CGFloat { min(620, max(300, windowHeight * 0.42)) }

    @ViewBuilder private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                previewPane(model.previewImage,
                            title: model.staged.hasPendingChanges ? "Your edit (not yet live)" : "Preview")
                if let compare = model.previewCompareImage {
                    // The reference: same stack, COMMITTED adjustments — what the audience sees
                    // right now. It holds still while the left pane follows the dials, so the
                    // difference between the panes is the edit and nothing else.
                    previewPane(compare, title: "Currently live")
                }
            }
            .frame(minHeight: 300, maxHeight: max(340, panelHeight))
            .overlay(alignment: .topLeading) {
                if model.staged.hasPendingChanges {
                    Text("Pending — not yet on the broadcast")
                        .font(.caption2).padding(4)
                        .background(.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }

            HStack {
                Text(comparisonStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { model.revertAdjustments() }
                    .disabled(!model.staged.hasPendingChanges)
                Button("Apply") { model.applyAdjustments() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.staged.hasPendingChanges)
            }
        }
    }

    /// One labelled pane of the comparison.
    @ViewBuilder private func previewPane(_ image: CGImage?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .overlay(Text(model.isRunning ? "No stack yet"
                                                      : "Preview available during live sessions")
                                    .font(.caption).foregroundStyle(.secondary))
                }
            }
        }
    }

    /// Explains itself when there is nothing to compare, rather than silently showing one pane.
    private var comparisonStatus: String {
        guard model.staged.hasPendingChanges else {
            switch model.liveRejectionStatus {
            case .active(let subs): return "Clean master over \(subs) subs · move a slider to compare against what is live"
            case .building(let subs): return "Building the clean master over \(subs) subs"
            case .off(let reason): return "Trail rejection off (\(reason))"
            }
        }
        return "Left: your pending edit · Right: what the broadcast is showing now"
    }

}
