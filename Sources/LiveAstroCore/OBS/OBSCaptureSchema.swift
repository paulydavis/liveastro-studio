import Foundation

/// Wire schema for the macOS window-capture input, grounded in the Task-1
/// probe of real OBS 32.1.2 (docs/superpowers/reviews/2026-08-06-obs-capture-
/// schema.md). OBS persists the binding ONLY as a numeric CGWindowID
/// ("window") plus a capture-mode discriminator ("type": 1 = Window Capture);
/// there is NO title/owner string in settings, and a saved id goes stale when
/// the window is recreated — callers re-derive the id from the live broadcast
/// window at every Go Live. If the probe record and this file disagree, the
/// probe record wins — re-run the probe before editing here.
enum OBSCaptureSchema {
    static let inputKind = "screen_capture"

    /// Minimal settings that (re)bind the capture to our window. Applied via
    /// SetInputSettings with overlay:true, so OBS keeps its own defaults for
    /// display_uuid / show_* keys.
    static func settings(windowID: UInt32) -> [String: Any] {
        ["type": 1, "window": Int(windowID)]
    }

    /// Does an existing input's settings target our window RIGHT NOW?
    static func targetsWindow(_ settings: [String: Any], windowID: UInt32) -> Bool {
        settings["type"] as? Int == 1 && settings["window"] as? Int == Int(windowID)
    }
}
