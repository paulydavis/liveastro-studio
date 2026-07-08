import SwiftUI
import AppKit

private enum AppLayout {
    static let broadcastAspect: CGFloat = 16.0 / 9.0
    static let broadcastDefaultSize = CGSize(width: 1280, height: 720)
    static let broadcastMinSize = CGSize(width: 640, height: 360)
    static let controlDefaultSize = CGSize(width: 460, height: 640)
}

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
        .defaultSize(AppLayout.controlDefaultSize)

        Window("LiveAstro Broadcast", id: "broadcast") {
            BroadcastView()
                .environment(model)
                .aspectRatio(AppLayout.broadcastAspect, contentMode: .fit)
                .frame(minWidth: AppLayout.broadcastMinSize.width,
                       minHeight: AppLayout.broadcastMinSize.height)
                .background(Color.black)   // letterbox any non-16:9 window slack in black
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(AppLayout.broadcastDefaultSize)
    }
}
