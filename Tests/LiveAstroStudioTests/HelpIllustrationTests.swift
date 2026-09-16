import XCTest
import AppKit
import SwiftUI
import Vision
@testable import LiveAstroStudio

final class HelpIllustrationTests: XCTestCase {
    // Break: starting the disclosure collapsed hides the image and its enlargement hint.
    @MainActor func testScreenshotIsVisibleWithoutExpandingDisclosure() async throws {
        let illustration = try XCTUnwrap(HelpIllustration.forTopic("Quick Start"))
        let host = NSHostingView(rootView: HelpIllustrationView(illustration: illustration)
            .padding().frame(width: 800, height: 650).background(Color.white)
            .environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var text = ""
        repeat {
            try await Task.sleep(for: .milliseconds(25))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if text.contains("Click the image to enlarge") { return }
        } while clock.now < deadline
        XCTFail("Screenshot content was not visible by default. Rendered text: \(text)")
    }

    // Break: a mapped topic ships without its readable native screenshot resource.
    func testIllustratedTopicsLoadDecodableScreenshots() throws {
        for title in ["Quick Start", "Calibration", "Display Adjustments", "Session Outputs"] {
            let illustration = try XCTUnwrap(HelpIllustration.forTopic(title), title)
            let image = try XCTUnwrap(illustration.image, title)
            XCTAssertGreaterThan(image.size.width, 300)
            XCTAssertGreaterThan(image.size.height, 80)
            XCTAssertFalse(illustration.accessibilityDescription.isEmpty)
        }
    }

    // Break: every setting popover is burdened with an unrelated screenshot.
    func testUnillustratedTopicDoesNotReceiveAnotherTopicsImage() {
        XCTAssertNil(HelpIllustration.forTopic("Black point"))
        XCTAssertNil(HelpIllustration.forTopic("Missing topic"))
    }
}
