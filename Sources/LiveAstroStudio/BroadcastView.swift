import SwiftUI
import AppKit
import LiveAstroCore

/// Overlay metrics, expressed at the 1080p reference height and scaled
/// to the actual window height so OBS captures stay proportionate.
private enum BroadcastLayout {
    static let referenceHeight: CGFloat = 1080
    static let titleSize: CGFloat = 54
    static let captionSize: CGFloat = 34
    static let equipmentSize: CGFloat = 24
    static let elapsedSize: CGFloat = 28
    static let safePadding: CGFloat = 64
    static let shadowRadius: CGFloat = 6
    static let shadowOpacity: Double = 0.8
}

/// The OBS-captured scene: dark, non-interactive, never blanks (spec §5.6).
struct BroadcastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.height / BroadcastLayout.referenceHeight
            ZStack {
                Color.black
                if let cg = model.latestImage {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
                overlay(scale: scale)
            }
            .ignoresSafeArea()
            .background(BroadcastWindowConfigurator())
        }
    }

    private func overlay(scale: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.targetName.isEmpty ? "LiveAstro" : model.targetName)
                        .font(.system(size: BroadcastLayout.titleSize * scale, weight: .bold, design: .rounded))
                    Text(model.integrationCaption)
                        .font(.system(size: BroadcastLayout.captionSize * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(equipmentLine)
                        .font(.system(size: BroadcastLayout.equipmentSize * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsedLine)
                        .font(.system(size: BroadcastLayout.elapsedSize * scale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(BroadcastLayout.safePadding * scale)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(BroadcastLayout.shadowOpacity),
                radius: BroadcastLayout.shadowRadius * scale)
    }

    private var equipmentLine: String {
        var parts = [model.telescope, model.camera].filter { !$0.isEmpty }
        if !model.locationLabel.isEmpty {
            let bortle = model.bortleText.isEmpty ? "" : " · Bortle \(model.bortleText)"
            parts.append(model.locationLabel + bortle)
        }
        return parts.joined(separator: "  ·  ")
    }

    private var elapsedLine: String {
        guard let start = model.sessionStart else { return "" }
        let ref = model.sessionEnd ?? Date()
        let s = Int(ref.timeIntervalSince(start))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// Gives the hidden-titlebar broadcast window a real window-server title so
/// OBS/ScreenCaptureKit list it, while keeping the chrome invisible.
/// Not unit-testable: needs a live window server — validated visually via
/// OBS window capture.
struct BroadcastWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = "LiveAstro Broadcast"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            if !window.styleMask.contains(.titled) {
                window.styleMask.insert(.titled)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
