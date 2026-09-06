import SwiftUI

struct DisplaySettingsView: View {
    @Bindable var model: AppModel

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
    }

    @ViewBuilder private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let cg = model.previewImage {
                    Image(decorative: cg, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .overlay(Text(model.isRunning ? "No stack yet"
                                                       : "Preview available during live sessions")
                                    .font(.caption).foregroundStyle(.secondary))
                }
            }
            .frame(maxHeight: 260)
            .overlay(alignment: .topLeading) {
                if model.staged.hasPendingChanges {
                    Text("Pending — not yet on the broadcast")
                        .font(.caption2).padding(4)
                        .background(.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }

            HStack {
                blinkButton
                Spacer()
                Button("Revert") { model.revertAdjustments() }
                    .disabled(!model.staged.hasPendingChanges)
                Button("Apply") { model.applyAdjustments() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.staged.hasPendingChanges)
            }
        }
    }

    @ViewBuilder private var blinkButton: some View {
        let status = model.liveRejectionStatus
        let (enabled, label): (Bool, String) = {
            switch status {
            case .active(let subs): return (true, "Hold to compare (clean, \(subs) subs)")
            case .building(let subs): return (false, "Building over \(subs) subs…")
            case .off(let reason): return (false, "Comparison unavailable — \(reason)")
            }
        }()
        Text(label)
            .font(.caption)
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .opacity(enabled ? 1 : 0.5)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, !model.blinkHeld else { return }
                        model.blinkHeld = true               // held: show the UN-rejected master
                        model.refreshPreview(force: true)     // discrete action — never throttle it away
                    }
                    .onEnded { _ in
                        // Must NOT gate on `enabled`: it derives from liveRejectionStatus, which can
                        // flip to .building between press and release (a reject, a kappa change, a
                        // reseed, a budget change, or the feature toggle). Gating the release on it
                        // would swallow the release, strand blinkHeld true forever, and leave the
                        // panel showing the un-rejected master under a "clean" label.
                        guard model.blinkHeld else { return }
                        model.blinkHeld = false              // released: back to the clean one
                        model.refreshPreview(force: true)     // a swallowed release would strand the panel on online
                    }
            )
            .help("Hold to see the stack WITHOUT trail rejection. Each side is auto-stretched from "
                + "its own statistics, so the overall brightness shifts too — look for the trail, not the tone.")
            .onDisappear {
                // Safety net for a release that never arrives. Guarding onEnded on `blinkHeld`
                // handles a stale release, but not a gesture that is ABANDONED: `selectLiveTab`
                // (AppModel.swift:346, fired asynchronously by live-source auto-detect) switches
                // `selectedTab` away from .setup, which tears this view out of the hierarchy
                // mid-drag. SwiftUI does not run pending completion closures on teardown, so
                // without this `blinkHeld` would stay true forever and `previewSource` would
                // return .online permanently — the panel showing the un-rejected master under a
                // "clean" label, which is exactly the failure the guard was added to prevent.
                if model.blinkHeld {
                    model.blinkHeld = false
                    model.refreshPreview(force: true)
                }
            }
    }
}
