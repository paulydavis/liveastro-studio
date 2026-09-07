import SwiftUI

struct DisplaySettingsView: View {
    @Bindable var model: AppModel

    @State private var windowHeight: CGFloat = 800

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // LEFT COLUMN: what the audience sees on top, what you are editing underneath.
            VStack(spacing: 10) {
                previewPane(model.previewCompareImage, title: "Currently live",
                            histogram: model.compareHistogram)
                previewPane(model.previewImage,
                            title: "Your edit",
                            badge: model.staged.hasPendingChanges ? "Not yet live" : nil,
                            histogram: model.previewHistogram)
                HStack {
                    Button("Revert") { model.revertAdjustments() }
                        .disabled(!model.staged.hasPendingChanges)
                    Button("Apply") { model.applyAdjustments() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.staged.hasPendingChanges)
                }
                Text(comparisonStatus)
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // RIGHT COLUMN: the controls.
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
                            HStack {
                                Slider(value: $model.staged.pending.blackPoint, in: 0...0.05)
                                    .onChange(of: model.staged.pending.blackPoint) { _, _ in
                                        model.refreshPreview()
                                    }
                                Text(String(format: "%.4f", model.staged.pending.blackPoint))
                                    .frame(width: 62, alignment: .trailing).monospacedDigit()
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .help("Darken the sky background. 0 = auto. Range narrowed to 0-0.05: "
                                + "the auto-stretch re-derives after this clip, so larger values do "
                                + "very little. Click the slider and use arrow keys for fine steps.")
                        }
                        VStack(alignment: .leading) {
                            Text("Stretch strength")
                            HStack {
                                Slider(value: $model.staged.pending.midtoneStrength, in: -1...1)
                                    .onChange(of: model.staged.pending.midtoneStrength) { _, _ in
                                        model.refreshPreview()
                                    }
                                Text(String(format: "%+.3f", model.staged.pending.midtoneStrength))
                                    .frame(width: 62, alignment: .trailing).monospacedDigit()
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .help("How aggressive the stretch is. 0 = auto. Click the slider and use "
                                + "arrow keys for fine steps.")
                        }
                        VStack(alignment: .leading) {
                            Text("Saturation")
                            HStack {
                                Slider(value: $model.staged.pending.saturation, in: 0...2)
                                    .onChange(of: model.staged.pending.saturation) { _, _ in
                                        model.refreshPreview()
                                    }
                                Text(String(format: "%.3f", model.staged.pending.saturation))
                                    .frame(width: 62, alignment: .trailing).monospacedDigit()
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .help("Color intensity. 1 = unchanged. Click the slider and use arrow "
                                + "keys for fine steps.")
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
                                Text(String(format: "%.2f%%", model.staged.pending.bgScale))
                                    .frame(width: 48, alignment: .trailing).monospacedDigit()
                            }
                            .help("Smoothing scale as % of image size — lower follows local/corner gradients, higher removes only broad gradients.")
                            HStack {
                                Text("Smoothest").frame(width: 90, alignment: .leading)
                                Slider(value: $model.staged.pending.bgSmoothest, in: 0...3)
                                    .onChange(of: model.staged.pending.bgSmoothest) { _, _ in
                                        model.refreshPreview()
                                    }
                                Text(String(format: "%.2f", model.staged.pending.bgSmoothest))
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
            // Pinned rather than flexible: the controls need a readable width and no more, so
            // every remaining pixel goes to the images. They were ~555pt wide in a 2000pt window.
            .frame(width: 380)
        }
        .padding(.horizontal).padding(.top)
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

    /// Small histogram inset, drawn in the corner OF the image.
    ///
    /// FIXED 0-255 axis, deliberately. An earlier version auto-ranged to the populated span, which
    /// defeats the purpose: when a stretch shifts the whole distribution brighter, an auto-ranged
    /// view rescales and looks identical, so the adjustment appears to do nothing. On a fixed axis
    /// the histogram visibly slides and spreads as the dials move, which is the entire point of
    /// having it while editing.
    ///
    /// SQRT counts: sky background outnumbers stars by orders of magnitude, so a linear axis
    /// hides the tail entirely; log flattens the background spike into a ramp and hides the
    /// landmark. Square root keeps both readable.
    ///
    /// The end bins are called out in red when they hold a meaningful share of the frame — that
    /// is shadows crushed to black or highlights blown to white, the two things an adjustment can
    /// destroy irreversibly and the reason to look at a histogram at all while editing.
    @ViewBuilder private func histogramInset(_ counts: [Int]) -> some View {
        if !counts.isEmpty {
            let total = max(counts.reduce(0, +), 1)
            let peak = max(1.0, Double(counts.max() ?? 1).squareRoot())
            let shadowClip = Double(counts.first ?? 0) / Double(total)
            let highlightClip = Double(counts.last ?? 0) / Double(total)
            VStack(spacing: 2) {
                GeometryReader { geo in
                    Path { path in
                        let w = geo.size.width / CGFloat(counts.count)
                        for (i, c) in counts.enumerated() {
                            let hgt = CGFloat(Double(c).squareRoot() / peak) * geo.size.height
                            path.addRect(CGRect(x: CGFloat(i) * w, y: geo.size.height - hgt,
                                                width: max(w - 0.4, 0.4), height: max(hgt, c > 0 ? 0.8 : 0)))
                        }
                    }
                    .fill(.white.opacity(0.85))
                    .overlay(alignment: .leading) {
                        if shadowClip > 0.005 {
                            Rectangle().fill(.red.opacity(0.75))
                                .frame(width: max(geo.size.width / CGFloat(counts.count), 2))
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if highlightClip > 0.005 {
                            Rectangle().fill(.red.opacity(0.75))
                                .frame(width: max(geo.size.width / CGFloat(counts.count), 2))
                        }
                    }
                }
                .frame(width: 220, height: 56)
                HStack(spacing: 0) {
                    Text(shadowClip > 0.005 ? String(format: "clipped %.1f%%", shadowClip * 100) : "0")
                        .foregroundStyle(shadowClip > 0.005 ? .red : .secondary)
                    Spacer()
                    Text(highlightClip > 0.005 ? String(format: "blown %.1f%%", highlightClip * 100) : "255")
                        .foregroundStyle(highlightClip > 0.005 ? .red : .secondary)
                }
                .font(.system(size: 9)).frame(width: 220)
            }
            .padding(6)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            .padding(8)
        }
    }

    @ViewBuilder private func previewPane(_ image: CGImage?, title: String,
                                          badge: String? = nil,
                                          histogram: [Int] = []) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .overlay(Text(model.isRunning ? "No stack yet"
                                                      : "Preview available during live sessions")
                                    .font(.caption).foregroundStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Label and badge overlay the IMAGE. Anchoring them to the pane's frame left them
            // stranded at the far edge once the frame grew to fill the column.
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.black)
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .bottomLeading) { histogramInset(histogram) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        return "Top: what the broadcast is showing now · Bottom: your pending edit"
    }

}
