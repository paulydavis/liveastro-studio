import Foundation
import XCTest

enum CrashArtifactError: Error, CustomStringConvertible {
    case helperNotFound(URL)
    case readyTimeout(String)
    var description: String {
        switch self {
        case .helperNotFound(let u): return "faulthelper not found at \(u.path) (build products dir)"
        case .readyTimeout(let s): return "faulthelper never touched its READY flag: \(s)"
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
                process.terminate()
                throw CrashArtifactError.readyTimeout("no flag within 30s (scenario \(scenario))")
            }
            _ = tick.wait(timeout: .now() + 0.02)   // short bounded wait; loop re-checks the flag
        }

        // The helper has reached its coordinated point (flag touched). SIGKILL lands mid-state.
        // NOTE (F3/review3): for `manifest-midwrite` the injected SessionManager.manifestWriter seam
        // touches the flag only AFTER staging a new manifest version to a same-dir temp file (with
        // the atomic rename/publish still pending), so this kill lands within an open write
        // transaction (staged-but-unpublished data, or a subsequent iteration's staged write) — not
        // on a pre-seeded manifest sitting idle before the first challenged write.
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        return aftermath
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
