import XCTest
import SwiftUI
import Vision
@testable import LiveAstroCore
@testable import LiveAstroStudio

/// Keep rendered-UI evidence separate from controller tests. Removing the button
/// must fail this test, even if cancelDetection works. Real button activation is
/// checked manually in the signed preview; this test checks rendered availability.
@MainActor
final class CameraSearchPresentationTests: XCTestCase {
    func testCancelIsVisibleFromAnotherSetupTabWhilePermissionIsBlocked() async throws {
        let suite = "CameraSearchPresentationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = AppModel(userDefaults: defaults,
            calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("library")),
            configuration: StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview", containerRoot: root))
        var permission: CheckedContinuation<FileAccessLease?, Never>?
        let entered = expectation(description: "permission acquisition parked")
        model.liveSource = LiveSourceController(surface: AppSurface(log: { _ in }, presentError: { _ in XCTFail("cancelled search must not report an error") },
            isSessionRunning: { false }, startSession: { _ in XCTFail("cancelled search started") },
            acquireCameraShare: { _, _ in await withCheckedContinuation { permission = $0; entered.fulfill() } },
            isStorePreview: true), relayRoot: root.appendingPathComponent("relay"))
        defer {
            model.liveSource.stopRelay()
            permission?.resume(returning: nil)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        model.setupSubTab = .diagnostics
        let host = NSHostingView(rootView: ControlView().environment(model).frame(width: 1000, height: 850))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        model.liveSource.startSeestarLive()
        await fulfillment(of: [entered], timeout: 5)

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var labels = ""
        repeat {
            try await Task.sleep(for: .milliseconds(25))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        } while !labels.contains("Cancel source search") && ContinuousClock.now < deadline
        XCTAssertTrue(labels.contains("Cancel source search"), "Cancel must be visible outside Capture: \(labels)")
        XCTAssertTrue(model.liveSource.isDetecting, "permission must remain parked throughout the UI check")
    }
}
