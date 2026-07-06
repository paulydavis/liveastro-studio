import SwiftUI
import LiveAstroCore

/// The OBS-captured scene: dark, non-interactive, never blanks (spec §5.6).
struct BroadcastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.height / 1080
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
        }
    }

    private func overlay(scale: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.targetName.isEmpty ? "LiveAstro" : model.targetName)
                        .font(.system(size: 54 * scale, weight: .bold, design: .rounded))
                    Text(model.integrationCaption)
                        .font(.system(size: 34 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(equipmentLine)
                        .font(.system(size: 24 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsedLine)
                        .font(.system(size: 28 * scale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(64 * scale) // safe margins
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 6 * scale)
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
