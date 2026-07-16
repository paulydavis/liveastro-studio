import AppKit

/// App-side OBS launch adapter — the platform half of the core↔app boundary.
///
/// `BroadcastController` (LiveAstroCore) only *requests* a launch through its
/// injected `BroadcastDeps.launchOBS` closure; this adapter owns every
/// platform detail: bundle-id resolution, the `open -a OBS` fallback, and all
/// launch logging. NSWorkspace/AppKit stays app-target-only (never in core).
@MainActor
enum OBSLauncher {

    /// Bundle id used to resolve + launch OBS.
    static let obsBundleID = "com.obsproject.obs-studio"

    /// Launch OBS via NSWorkspace by bundle id; fall back to `open -a OBS`.
    static func launch(log: @escaping (String) -> Void) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: obsBundleID) {
            log("OBS: launching \(url.lastPathComponent)…")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error {
                    Task { @MainActor in log("OBS: launch failed: \(error.localizedDescription)") }
                }
            }
        } else {
            // Bundle id not resolvable — try the command-line fallback, and if
            // that isn't available either, just skip the launch and log.
            log("OBS: app not found by bundle id — trying `open -a OBS`")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "OBS"]
            do {
                try process.run()
            } catch {
                log("OBS: could not launch OBS (\(error.localizedDescription)) — skipping")
            }
        }
    }
}
