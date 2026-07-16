import Foundation
import XCTest

enum CrashArtifactError: Error, CustomStringConvertible {
    case helperNotFound(URL)
    case readyTimeout(String)
    case killFailed(String, Int32)
    case notKilledBySIGKILL(String, Process.TerminationReason, Int32)
    var description: String {
        switch self {
        case .helperNotFound(let u): return "faulthelper not found at \(u.path) (build products dir)"
        case .readyTimeout(let s): return "faulthelper never touched its READY flag: \(s)"
        case .killFailed(let s, let err):
            return "kill(SIGKILL) failed for scenario \(s): errno \(err)"
        case .notKilledBySIGKILL(let s, let reason, let status):
            return "faulthelper (scenario \(s)) did not die by SIGKILL: " +
                   "terminationReason=\(reason == .uncaughtSignal ? "uncaughtSignal" : "exit"), status=\(status)"
        }
    }
}

/// Drives the separate `faulthelper` executable to a coordinated point, SIGKILLs it, and returns
/// the genuine on-disk aftermath directory — so restart/recovery tests run against a REAL killed
/// process's state, not merely objects released in-process (spec engineering rule).
enum CrashArtifactBuilder {
    /// Runs `faulthelper <scenario> <aftermathRoot> <flag>`, waits for the flag file to appear
    /// (the helper touches it at its coordinated point then blocks forever), SIGKILLs the process,
    /// and returns the aftermath directory the helper wrote into.
    static func killedArtifact(scenario: String, in tempFS: TempFS) throws -> URL {
        let aftermath = try tempFS.dir("aftermath-\(scenario)")
        let flag = tempFS.root.appendingPathComponent("ready-\(scenario)-\(UUID().uuidString).flag")

        let process = Process()
        process.executableURL = try helperURL()
        // For relay-midcopy the helper needs <src> <dst>; we pass the aftermath dir as the root and
        // let the helper carve subdirs. All scenarios take: <scenario> <root> <flag>.
        process.arguments = [scenario, aftermath.path, flag.path]
        // Silence helper output (it blocks forever; we don't read its pipes).
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Guaranteed cleanup on EVERY error path from here on (review5 P3): the helper blocks
        // forever by design, so any throw that leaves it running would leak a child into the
        // test run — and the old readiness-timeout path only sent SIGTERM without reaping.
        // A defer cannot be bypassed by any of the throws below: on an error exit it force-kills
        // (SIGKILL, errors ignored — the helper never handles it away) any still-running child
        // and reaps it via waitUntilExit(). The success path is unchanged (it has already
        // SIGKILLed, reaped, and verified death-by-signal before `completed` is set).
        var completed = false
        defer { if !completed { forceKillAndReap(process) } }

        // Readiness detection across a process boundary: poll the flag with a short
        // DispatchSemaphore-timed loop. This is readiness detection (waiting for the helper to
        // REACH its coordinated point), NOT race synchronization — the spec explicitly permits it.
        let deadline = Date().addingTimeInterval(30)
        let tick = DispatchSemaphore(value: 0)
        while !FileManager.default.fileExists(atPath: flag.path) {
            if !process.isRunning {
                throw CrashArtifactError.readyTimeout("helper exited before signaling ready (scenario \(scenario))")
            }
            if Date() >= deadline {
                // Cleanup (SIGKILL + reap) happens in the defer above — no terminate-and-leak.
                throw CrashArtifactError.readyTimeout("no flag within 30s (scenario \(scenario))")
            }
            _ = tick.wait(timeout: .now() + 0.02)   // short bounded wait; loop re-checks the flag
        }

        // The helper has reached its coordinated point (flag touched). SIGKILL lands mid-state.
        // NOTE (review4, supersedes the review3 note): for `manifest-midwrite` the injected
        // SessionManager.manifestWriter seam stages the challenged version to a same-dir temp,
        // touches the flag, and BLOCKS FOREVER (never publishes) — so this kill lands
        // DETERMINISTICALLY between staging and publication of the challenged write: the staged
        // temp is complete, closed, and unpublished; the previously published manifest is intact.
        // (The seam exists because a block-point cannot be interposed inside production
        // `Data(.atomic)`; the writer performs byte-identical staging steps, and the production
        // path's crash-atomicity is separately covered by the APFS in-place cells.)
        //
        // Review4 hardening (ALL scenarios): the kill must SUCCEED and the helper must die BY
        // SIGKILL — a helper that exited cleanly (or was reaped some other way) would yield an
        // aftermath that is not a killed-process artifact at all. Foundation's Process reaps the
        // child itself (never call waitpid here — it races Process's own child handling);
        // terminationReason == .uncaughtSignal with terminationStatus == SIGKILL distinguishes
        // death-by-signal-9 from any exit path.
        guard kill(process.processIdentifier, SIGKILL) == 0 else {
            throw CrashArtifactError.killFailed(scenario, errno)
        }
        process.waitUntilExit()
        guard process.terminationReason == .uncaughtSignal,
              process.terminationStatus == SIGKILL else {
            throw CrashArtifactError.notKilledBySIGKILL(scenario, process.terminationReason,
                                                        process.terminationStatus)
        }
        completed = true
        return aftermath
    }

    /// Error-path cleanup (review5 P3): force-kill any still-running helper (SIGKILL — errors
    /// deliberately ignored; a failed kill of an already-dead child is fine) and REAP it via
    /// Process's own waitUntilExit (never raw waitpid — it races Foundation's child handling).
    /// Idempotent for already-exited children: the kill is skipped and waitUntilExit returns
    /// immediately once Foundation has observed the exit.
    private static func forceKillAndReap(_ process: Process) {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    /// Locate the `faulthelper` executable. Under `swift test` (and Xcode), SPM places the built
    /// executable in the SAME products directory as the .xctest bundle, so it is the xctest
    /// bundle's parent directory. This is the canonical `productsDirectory` convention.
    private static func helperURL() throws -> URL {
        let productsDir = try productsDirectory()
        let candidate = productsDir.appendingPathComponent("faulthelper")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw CrashArtifactError.helperNotFound(candidate)
        }
        return candidate
    }

    /// The build products directory — parent of the running .xctest bundle.
    private static func productsDirectory() throws -> URL {
        // Bundle.allBundles includes the .xctest bundle on macOS; its parent is the products dir.
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        // Fallback: derive from THIS bundle (the test bundle) via a class in it.
        return Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
    }
}

/// Anchor class whose bundle is the test bundle, used to locate the products directory.
private final class BundleAnchor {}
