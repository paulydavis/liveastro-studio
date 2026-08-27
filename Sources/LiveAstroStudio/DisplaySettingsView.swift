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
                        Slider(value: $model.displayAdjustments.blackPoint, in: 0...0.2) { editing in
                            if !editing { model.applyDisplayAdjustments() }
                        }
                        .help("Darken the sky background. 0 = auto.")
                    }
                    VStack(alignment: .leading) {
                        Text("Stretch strength")
                        Slider(value: $model.displayAdjustments.midtoneStrength, in: -1...1) { editing in
                            if !editing { model.applyDisplayAdjustments() }
                        }
                        .help("How aggressive the stretch is. 0 = auto.")
                    }
                    VStack(alignment: .leading) {
                        Text("Saturation")
                        Slider(value: $model.displayAdjustments.saturation, in: 0...2) { editing in
                            if !editing { model.applyDisplayAdjustments() }
                        }
                        .help("Color intensity. 1 = unchanged.")
                    }
                    helpToggle("Flatten background (DBE)", isOn: $model.displayAdjustments.backgroundExtraction,
                               help: "Remove the light-pollution gradient so the sky darkens evenly. Off by default.")
                        .onChange(of: model.displayAdjustments.backgroundExtraction) { _, _ in
                            model.applyDisplayAdjustments()
                        }
                    if model.displayAdjustments.backgroundExtraction {
                        HStack {
                            Text("Scale").frame(width: 90, alignment: .leading)
                            Slider(value: $model.displayAdjustments.bgScale, in: 1...15) { editing in
                                if !editing { model.applyDisplayAdjustments() }
                            }
                            Text(String(format: "%.1f%%", model.displayAdjustments.bgScale))
                                .frame(width: 48, alignment: .trailing).monospacedDigit()
                        }
                        .help("Smoothing scale as % of image size — lower follows local/corner gradients, higher removes only broad gradients.")
                        HStack {
                            Text("Smoothest").frame(width: 90, alignment: .leading)
                            Slider(value: $model.displayAdjustments.bgSmoothest, in: 0...3) { editing in
                                if !editing { model.applyDisplayAdjustments() }
                            }
                            Text(String(format: "%.1f", model.displayAdjustments.bgSmoothest))
                                .frame(width: 48, alignment: .trailing).monospacedDigit()
                        }
                        .help("Extra blur on the background model — raise to remove residual blotchiness, lower to track non-smooth gradients.")
                    }
                    VStack(alignment: .leading) {
                        Text("Denoise")
                        Slider(value: $model.displayAdjustments.denoiseStrength, in: 0...1) { editing in
                            if !editing { model.applyDisplayAdjustments() }
                        }
                        .help("Classic noise reduction — smooths background grain and color mottle on the displayed stack. 0 = off. master.fit is never modified.")
                    }
                    switch model.catalogState {
                    case .installed:
                        helpToggle("North up", isOn: $model.displayAdjustments.northUp,
                                   help: "Rotate the view so celestial north is up (display only — master.fit stays native). Needs a plate solve; enabled once the reference frame is solved.")
                            .onChange(of: model.displayAdjustments.northUp) { _, _ in
                                model.applyDisplayAdjustments()
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
                        model.displayAdjustments = .liveDefault
                        model.applyDisplayAdjustments()
                    }
                    .help("Back to the recommended look (auto-stretch with background flattening on).")
                }
            }
            .formStyle(.grouped)
            .background(AlwaysVisibleScroller())
        }
        .scrollIndicators(.visible)
    }
}
