import SwiftUI

struct DisplaySettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
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
                        Slider(value: $model.staged.pending.blackPoint, in: 0...0.2) { editing in
                            if !editing { model.refreshPreview() }
                        }
                        .help("Darken the sky background. 0 = auto.")
                    }
                    VStack(alignment: .leading) {
                        Text("Stretch strength")
                        Slider(value: $model.staged.pending.midtoneStrength, in: -1...1) { editing in
                            if !editing { model.refreshPreview() }
                        }
                        .help("How aggressive the stretch is. 0 = auto.")
                    }
                    VStack(alignment: .leading) {
                        Text("Saturation")
                        Slider(value: $model.staged.pending.saturation, in: 0...2) { editing in
                            if !editing { model.refreshPreview() }
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
                            Slider(value: $model.staged.pending.bgScale, in: 1...15) { editing in
                                if !editing { model.refreshPreview() }
                            }
                            Text(String(format: "%.1f%%", model.staged.pending.bgScale))
                                .frame(width: 48, alignment: .trailing).monospacedDigit()
                        }
                        .help("Smoothing scale as % of image size — lower follows local/corner gradients, higher removes only broad gradients.")
                        HStack {
                            Text("Smoothest").frame(width: 90, alignment: .leading)
                            Slider(value: $model.staged.pending.bgSmoothest, in: 0...3) { editing in
                                if !editing { model.refreshPreview() }
                            }
                            Text(String(format: "%.1f", model.staged.pending.bgSmoothest))
                                .frame(width: 48, alignment: .trailing).monospacedDigit()
                        }
                        .help("Extra blur on the background model — raise to remove residual blotchiness, lower to track non-smooth gradients.")
                    }
                    VStack(alignment: .leading) {
                        Text("Denoise")
                        Slider(value: $model.staged.pending.denoiseStrength, in: 0...1) { editing in
                            if !editing { model.refreshPreview() }
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
                    // NOTE: this panel is a minimal compile-time adaptation to the new staged
                    // model (Task 5). It stages edits into `model.staged.pending` and re-renders
                    // the preview via `refreshPreview`, but does not yet expose Apply/Revert or
                    // the blink control, nor does it display `model.previewImage` — that UI
                    // (staged/committed indicator, Apply/Revert buttons, blink press-and-hold,
                    // preview image swap) is Task 6's job per the plan.
                }
            }
            .formStyle(.grouped)
            .background(AlwaysVisibleScroller())
        }
        .scrollIndicators(.visible)
    }
}
