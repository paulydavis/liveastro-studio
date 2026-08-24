import AppKit
import CoreGraphics
import LiveAstroCore

/// Applies and holds the red night-vision tint on the physical display(s).
///
/// The tint is a gamma-table remap — green and blue pinned to zero output, red
/// dimmed to the ``NightVision`` level — so the whole screen (every app, the menu
/// bar, the cursor) goes deep red. macOS clears a display's gamma when the
/// setting process exits, and also when a display sleeps or is reconfigured, so
/// this controller (living in the always-resident app process) re-applies on
/// display reconfiguration and on a low-frequency timer, and restores normal
/// color on ``disable()`` and at app termination.
///
/// Because macOS reverts gamma on process exit, quitting or crashing LiveAstro
/// auto-clears the tint — the Mac is never left stuck red.
///
/// Not unit-tested: `CGSetDisplayTransferByFormula` writes to real display
/// hardware and is a no-op under CI's headless WindowServer. The pure
/// level→gamma mapping it depends on is covered by `NightVisionTests`. Verified
/// by hand on the built-in display (2026-08-23): tint applies, survives display
/// sleep, and clears on quit.
final class NightModeController {
    private(set) var isActive = false
    private var current = NightVision()
    private var reconfigureRegistered = false
    private var reapplyTimer: Timer?

    /// Seconds between defensive re-applies while active — cheap insurance against
    /// Night Shift / power events that quietly reset the gamma table at the scope.
    private static let reapplyInterval: TimeInterval = 2.0

    init() {
        // Restore normal color the instant a normal quit begins (belt-and-suspenders;
        // process-exit revert would clear it regardless, but this is immediate).
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    /// Turn the tint on at `level`, or update the level if already on.
    func enable(level: Int) {
        current = NightVision(level: level)
        isActive = true
        registerReconfigurationCallbackIfNeeded()
        startTimer()
        apply()
    }

    /// Restore normal color and stop holding the tint.
    func disable() {
        isActive = false
        stopTimer()
        CGDisplayRestoreColorSyncSettings()
    }

    /// Re-apply at the current level. Called by the reconfiguration callback and the
    /// timer after a wake/reconnect (which clear the gamma table).
    func reapplyIfActive() {
        guard isActive else { return }
        apply()
    }

    // MARK: - Private

    private func apply() {
        let redMax = current.redMax
        for d in Self.onlineDisplays() {
            CGSetDisplayTransferByFormula(d,
                0.0, redMax, 1.0,   // red:   min 0, max = level, gamma 1
                0.0, 0.0,    1.0,   // green: output pinned to 0
                0.0, 0.0,    1.0)   // blue:  output pinned to 0
        }
    }

    private func startTimer() {
        guard reapplyTimer == nil else { return }
        let t = Timer(timeInterval: Self.reapplyInterval, repeats: true) { [weak self] _ in
            self?.reapplyIfActive()
        }
        RunLoop.main.add(t, forMode: .common)
        reapplyTimer = t
    }

    private func stopTimer() {
        reapplyTimer?.invalidate()
        reapplyTimer = nil
    }

    private func registerReconfigurationCallbackIfNeeded() {
        guard !reconfigureRegistered else { return }
        reconfigureRegistered = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            // Ignore the "begin" phase — the display is mid-change and would wipe our
            // write. Re-apply once it settles (any non-begin callback).
            guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
            Unmanaged<NightModeController>.fromOpaque(userInfo)
                .takeUnretainedValue().reapplyIfActive()
        }, ctx)
    }

    @objc private func handleAppWillTerminate() {
        if isActive { CGDisplayRestoreColorSyncSettings() }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
