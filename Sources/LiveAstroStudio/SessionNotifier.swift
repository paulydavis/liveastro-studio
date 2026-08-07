import Foundation
import UserNotifications

/// Posts macOS local notifications so an away/asleep operator is alerted when a
/// session safeguards or auto-ends (spec §2 notifications). No-ops silently if
/// notification permission is denied — the safeguard/stop still happen either way.
/// Not unit-tested: UNUserNotificationCenter needs a real notification service;
/// behavior is manual-verified (grant permission once, trip the idle timeout).
final class SessionNotifier {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func notifySafeguard() {
        post(title: "Capture idle", body: "No new frames — master saved. Session still running.")
    }
    func notifyPlannedStopEnd() {
        post(title: "Session complete", body: "Planned stop reached — master + replay written.")
    }
    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }
}
