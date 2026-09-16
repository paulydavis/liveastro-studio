import SwiftUI

/// Presentation-only palette. Do not apply to the image/broadcast rendering pipeline.
enum SetupStyle {
    static let background = Color(red: 0.09, green: 0.11, blue: 0.14)
    static let panel = Color(red: 0.125, green: 0.153, blue: 0.192)
    static let accent = Color(red: 0.87, green: 0.76, blue: 0.58)
}

struct SetupBrandHeader: View {
    private static let artwork: NSImage? = Bundle.module.url(forResource: "Sombrero", withExtension: "jpg")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                GeometryReader { geometry in
                    if let artwork = Self.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width * 0.5, height: 74)
                            .clipped()
                            .opacity(0.65)
                            .offset(x: geometry.size.width * 0.3)
                    }
                    LinearGradient(stops: [
                        .init(color: SetupStyle.panel, location: 0),
                        .init(color: SetupStyle.panel.opacity(0.95), location: 0.25),
                        .init(color: SetupStyle.panel.opacity(0.1), location: 0.45),
                        .init(color: SetupStyle.panel.opacity(0.1), location: 0.65),
                        .init(color: SetupStyle.panel, location: 0.85)
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .accessibilityHidden(true)
                Label("LiveAstro Studio", systemImage: "camera.aperture")
                    .labelStyle(.titleAndIcon)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(SetupStyle.accent)
                    .padding(.horizontal, 22)
            }
            .frame(height: 74)
            // Always-visible attribution also makes the fixed artwork's identity explicit.
            Link("Sombrero Galaxy • NASA/ESA and The Hubble Heritage Team (STScI/AURA)",
                 destination: URL(string: "https://esahubble.org/images/opo0328a/")!)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
        .background(SetupStyle.panel)
    }
}

struct SetupCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(SetupStyle.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}
