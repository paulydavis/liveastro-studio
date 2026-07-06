import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LiveAstroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(minWidth: 640, minHeight: 360)
                .background(Color.black)   // letterbox any non-16:9 window slack in black
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
    }
}
