import SwiftUI
import AppKit

private enum AppLayout {
    static let broadcastAspect: CGFloat = 16.0 / 9.0
    static let broadcastDefaultSize = CGSize(width: 1280, height: 720)
    static let broadcastMinSize = CGSize(width: 640, height: 360)
    static let mainDefaultSize = CGSize(width: 900, height: 720)
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var confirmRecordingQuit: () -> Bool = {
        OBSRecordingWarning.confirm(title: "Quit while OBS may be recording?", action: "Quit without stopping OBS")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.obsLocalRecording?.requiresAttention == true, !confirmRecordingQuit() {
            return .terminateCancel
        }
        return .terminateNow
    }
}

@MainActor enum OBSRecordingWarning {
    static func confirm(title: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "This does not stop OBS recording. Stop it separately in Broadcast, or in OBS if the connection is uncertain."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }
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
                .onAppear { appDelegate.model = model }
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
