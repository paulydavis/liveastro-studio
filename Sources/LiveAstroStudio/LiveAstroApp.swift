import SwiftUI
import AppKit

private enum AppLayout {
    static let broadcastAspect: CGFloat = 16.0 / 9.0
    static let broadcastDefaultSize = CGSize(width: 1280, height: 720)
    static let broadcastMinSize = CGSize(width: 640, height: 360)
    static let mainDefaultSize = CGSize(width: 900, height: 720)
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
        WindowGroup("LiveAstro") {
            MainView().environment(model)
        }
        .defaultSize(AppLayout.mainDefaultSize)

        Window("LiveAstro Broadcast", id: "broadcast") {
            BroadcastView()
                .environment(model)
                .aspectRatio(AppLayout.broadcastAspect, contentMode: .fit)
                .frame(minWidth: AppLayout.broadcastMinSize.width,
                       minHeight: AppLayout.broadcastMinSize.height)
                .background(Color.black)   // letterbox any non-16:9 window slack in black
                .onDisappear { model.isDetached = false }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(AppLayout.broadcastDefaultSize)
    }
}
