import SwiftUI
import AppKit

@main
struct LiveAstroApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("LiveAstro Control") {
            ControlView().environment(model)
        }
        .defaultSize(width: 460, height: 640)

        Window("LiveAstro Broadcast", id: "broadcast") {
            BroadcastView()
                .environment(model)
                .frame(width: 1920, height: 1080)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
