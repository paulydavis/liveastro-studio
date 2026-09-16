import XCTest
import SwiftUI
import Vision
@testable import LiveAstroCore
@testable import LiveAstroStudio

/// Regenerates documentation screenshots from production views, not hand-drawn mockups.
/// Opt in with LAS_HELP_CAPTURE_DIR pointing to an output directory; never uses real preferences.
final class HelpScreenshotCaptureTests: XCTestCase {
    @MainActor func testExportNativeHelpScreenshots() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAS_HELP_CAPTURE_DIR"] else {
            throw XCTSkip("Set LAS_HELP_CAPTURE_DIR to regenerate documentation screenshots.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "HelpScreenshotCapture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: library)
        }
        let model = AppModel(userDefaults: defaults, calibrationLibrary: CalibrationLibrary(baseDirectory: library))
        model.targetName = "Example session"
        model.sourceMode = .nativeStack
        model.watchFolder = URL(fileURLWithPath: "/Example/Capture/Lights")
        model.fileNamePrefix = "Light_"
        try await capture(CaptureSettingsView(model: model), size: CGSize(width: 1000, height: 570),
            crop: CGRect(x: 15, y: 105, width: 970, height: 270),
            requiredText: ["Filename prefix", "Light_"], name: "help-source", output: output)
        try await capture(CalibrationSection(model: model).padding(18), size: CGSize(width: 820, height: 350),
            requiredText: ["Add bias", "Dark-flats"], name: "help-calibration", output: output)
        try await capture(DisplaySettingsView(model: model), size: CGSize(width: 1100, height: 700),
            requiredText: ["Currently live", "Your edit", "Apply"], name: "help-display", output: output)
        // A replay-only example deliberately leaves Folder/Master unavailable; no fake output is created.
        model.replayURL = URL(fileURLWithPath: "/Example/Session/replay.mp4")
        try await capture(ControlView().environment(model), size: CGSize(width: 1000, height: 800),
            crop: CGRect(x: 0, y: 650, width: 1000, height: 128),
            requiredText: ["More outputs", "Replay"], name: "help-outputs", output: output)
    }

    @MainActor private func capture<V: View>(_ view: V, size: CGSize, crop: CGRect? = nil,
        requiredText: [String], name: String, output: URL) async throws {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(SetupStyle.background).environment(\.colorScheme, .dark).tint(SetupStyle.accent))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var recognized = ""
        repeat {
            try await Task.sleep(for: .milliseconds(25))
            host.layoutSubtreeIfNeeded()
            let rect = crop ?? host.bounds
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if requiredText.allSatisfy({ recognized.localizedCaseInsensitiveContains($0) }) {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent(name + ".png"))
                return
            }
        } while clock.now < deadline
        XCTFail("\(name) did not render the required controls. Recognized: \(recognized)")
    }
}
