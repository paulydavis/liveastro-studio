import AppKit
import CoreGraphics
import LiveAstroCore

/// Physical display boundary; injected tests never change the user's screen.
protocol NightDisplayAccessing {
    func onlineDisplays() throws -> [CGDirectDisplayID]
    func apply(display: CGDirectDisplayID, redMax: Float) throws
    func restore()
}

struct SystemNightDisplay: NightDisplayAccessing {
    func onlineDisplays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let result = CGGetOnlineDisplayList(0, nil, &count)
        guard result == .success else { throw DisplayFailure(code: result) }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listed = CGGetOnlineDisplayList(count, &ids, &count)
        guard listed == .success else { throw DisplayFailure(code: listed) }
        return Array(ids.prefix(Int(count)))
    }

    func apply(display: CGDirectDisplayID, redMax: Float) throws {
        let result = CGSetDisplayTransferByFormula(display, 0, redMax, 1, 0, 0, 1, 0, 0, 1)
        guard result == .success else { throw DisplayFailure(code: result) }
    }

    func restore() { CGDisplayRestoreColorSyncSettings() }

    private struct DisplayFailure: LocalizedError {
        let code: CGError
        var errorDescription: String? { "macOS display service returned error \(code.rawValue)." }
    }
}

/// Whole-display colour transform, never an image-processing operation.
/// All commands and lifecycle notifications are handled on the main thread.
/// API acceptance is not proof of physical output on every display: users must
/// check their screens, especially after wake, reconnect, or a colour-profile change.
final class NightModeController {
    private let display: any NightDisplayAccessing
    private let notifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var reapplyTimer: Timer?
    private var current = NightVision()
    private var hasWrittenDisplay = false
    private var sleepReasons: Set<String> = []
    private(set) var isActive = false
    var onFailure: ((String) -> Void)?

    private static let reapplyInterval: TimeInterval = 2

    init(display: any NightDisplayAccessing = SystemNightDisplay(),
         notifications: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.display = display
        self.notifications = notifications
        self.workspaceNotifications = workspaceNotifications
        observe(notifications, NSApplication.willTerminateNotification) { $0.disable() }
        // AppKit marshals display changes through its notification mechanism;
        // no unmanaged pointer is retained by a CoreGraphics callback.
        observe(notifications, NSApplication.didChangeScreenParametersNotification) { $0.reapplyIfActive() }
        observe(workspaceNotifications, NSWorkspace.screensDidSleepNotification) { $0.suspend("screen") }
        observe(workspaceNotifications, NSWorkspace.willSleepNotification) { $0.suspend("system") }
        observe(workspaceNotifications, NSWorkspace.screensDidWakeNotification) { $0.resume("screen") }
        observe(workspaceNotifications, NSWorkspace.didWakeNotification) { $0.resume("system") }
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        reapplyTimer?.invalidate()
        if hasWrittenDisplay { display.restore() }
    }

    func enable(level: Int) {
        current = NightVision(level: level)
        // A sleeping display is not a failed display; wake will apply the request.
        if !sleepReasons.isEmpty { isActive = true; return }
        guard apply() else { return }
        isActive = true
        startTimer()
    }

    func disable() {
        isActive = false
        stopTimer()
        restoreIfNeeded()
    }

    func reapplyIfActive() {
        guard isActive, sleepReasons.isEmpty else { return }
        _ = apply()
    }

    private func apply() -> Bool {
        do {
            let displays = try display.onlineDisplays()
            guard !displays.isEmpty else { throw NoDisplays() }
            for id in displays {
                // Even an unsuccessful write might have partially changed hardware.
                hasWrittenDisplay = true
                try display.apply(display: id, redMax: current.redMax)
            }
            return true
        } catch {
            isActive = false
            stopTimer()
            restoreIfNeeded()
            onFailure?("Red screen could not be applied to every display and has been turned off. Check your screens before continuing at the telescope. \(error.localizedDescription)")
            return false
        }
    }

    private func restoreIfNeeded() {
        guard hasWrittenDisplay else { return }
        display.restore() // ColorSync restore has no success/error return value.
        hasWrittenDisplay = false
    }

    private func suspend(_ reason: String) {
        sleepReasons.insert(reason)
        stopTimer()
    }

    private func resume(_ reason: String) {
        sleepReasons.remove(reason)
        guard isActive, sleepReasons.isEmpty else { return }
        reapplyIfActive()
        if isActive { startTimer() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping (NightModeController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            action(self)
        }
        observers.append((center, token))
    }

    private func startTimer() {
        guard reapplyTimer == nil else { return }
        let timer = Timer(timeInterval: Self.reapplyInterval, repeats: true) { [weak self] _ in
            self?.reapplyIfActive()
        }
        RunLoop.main.add(timer, forMode: .common)
        reapplyTimer = timer
    }

    private func stopTimer() {
        reapplyTimer?.invalidate()
        reapplyTimer = nil
    }

    private struct NoDisplays: LocalizedError {
        var errorDescription: String? { "No online display was found." }
    }
}
