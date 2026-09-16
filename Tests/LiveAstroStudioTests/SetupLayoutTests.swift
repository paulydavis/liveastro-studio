import XCTest
import SwiftUI
import Vision
@testable import LiveAstroCore
@testable import LiveAstroStudio

final class SetupLayoutTests: XCTestCase {
    @MainActor func testCaptureLayoutExposesCalibrationAndCurrentTarget() async throws {
        let suite = "SetupLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(userDefaults: defaults,
                             calibrationLibrary: CalibrationLibrary(baseDirectory: directory))
        model.targetName = "M 51"
        model.sourceMode = .nativeStack
        model.watchFolder = URL(fileURLWithPath: "/Example/ASIAIR/Autorun/Light")
        let host = NSHostingView(rootView: ControlView().environment(model)
            .frame(width: 1000, height: 850))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        // Observe rendered content rather than assuming layout completes after a fixed delay.
        // This is still a bounded GUI/OCR check, not a guarantee independent of machine load.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var labels = ""
        var capturedBitmap: NSBitmapImageRep?
        repeat {
            try await Task.sleep(for: .milliseconds(25))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            capturedBitmap = bitmap
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if labels.replacingOccurrences(of: " ", with: "").contains("M51"),
               labels.contains("Bias"), labels.contains("Dark-flats"), labels.contains("Start Session") {
                break
            }
        } while clock.now < deadline
        XCTAssertTrue(labels.replacingOccurrences(of: " ", with: "").contains("M51"), "The current target must remain visible, not replaced by the artwork's subject. \(labels)")
        XCTAssertTrue(labels.contains("Bias"), "Bias inventory must be visible without expanding calibration. \(labels)")
        XCTAssertTrue(labels.contains("Dark-flats"))
        XCTAssertTrue(labels.contains("Start Session"), "Primary start action must remain visible. \(labels)")

        // Optional visual evidence for a developer review; never changes user preferences.
        if let path = ProcessInfo.processInfo.environment["LAS_SETUP_SCREENSHOT"] {
            try XCTUnwrap(XCTUnwrap(capturedBitmap).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path))
        }
    }

}
