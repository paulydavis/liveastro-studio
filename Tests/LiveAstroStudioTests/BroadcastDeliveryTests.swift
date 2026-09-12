import XCTest
import SwiftUI
@testable import LiveAstroCore
@testable import LiveAstroStudio

final class BroadcastDeliveryTests: XCTestCase {
    @MainActor func testCapturedWindowUsesBroadcastPixelsInsteadOfOperatorPreview() async throws {
        let model = AppModel()
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        let pipeline = SessionPipeline(watchFolder: sandbox,
            profile: SessionProfile(targetName: "Broadcast", subExposureSeconds: 20), rootDirectory: sandbox)
        model.wireCallbacks(to: pipeline)
        let online = try XCTUnwrap(AutoStretch.makeCGImage(AstroImage(width: 512, height: 512,
            channels: 1, pixels: [Float](repeating: 0.8, count: 512 * 512), sourceIsLinear: false)))
        let clean = try XCTUnwrap(AutoStretch.makeCGImage(AstroImage(width: 512, height: 512,
            channels: 1, pixels: [Float](repeating: 0.2, count: 512 * 512), sourceIsLinear: false)))
        _ = try SnapshotRecorder(sessionDirectory: sandbox).save(cgImage: clean,
            linear: AstroImage(width: 512, height: 512, channels: 1,
                pixels: [Float](repeating: 0.2, count: 512 * 512), sourceIsLinear: false),
            sourceFile: "stack.fit", index: 1, timestamp: Date(), estimatedIntegrationSeconds: 140)
        let saved = try ImageLoader.load(url: sandbox.appendingPathComponent("latest.png"))
        // Same production callback the pipeline uses after saving the resolved broadcast image.
        pipeline.onDisplayUpdate?(DisplayDelivery(revision: 0, previewImage: online,
            broadcastImage: clean, cleanMasterSubCount: 7, integrationSeconds: 140,
            previewIntegrationSeconds: 200, subExposureSeconds: 20, record: nil))
        let applied = expectation(description: "main actor callback")
        Task { @MainActor in applied.fulfill() }
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertNotNil(model.latestImage, "paired callback must install the operator image too")
        XCTAssertEqual(model.liveRejectionStatus, .active(subs: 7),
                       "caption must describe the delivered clean pixels, not separately polled pipeline state")
        XCTAssertEqual(model.broadcastIntegrationCaption, "2m 20s · 7 × 20s")
        XCTAssertEqual(model.integrationCaption, "3m 20s · 10 × 20s")
        let view = NSHostingView(rootView: BroadcastView(configuresWindow: true)
            .environment(model).frame(width: 512, height: 512))
        view.frame = CGRect(x: 0, y: 0, width: 512, height: 512)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let rendered = try XCTUnwrap(bitmap.cgImage)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
            bytesPerRow: 512 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(bytes[(256 * 512 + 256) * 4], 100,
                          "center of captured window must show dark clean master, not bright online preview")
        XCTAssertEqual(Double(bytes[(256 * 512 + 256) * 4]), Double(saved.stats[0].mean) * 255, accuracy: 2,
                       "window pixels must match latest.png within display color conversion rounding")
        let operatorView = NSHostingView(rootView: BroadcastView(configuresWindow: false)
            .environment(model).frame(width: 512, height: 512))
        operatorView.frame = view.frame
        operatorView.layoutSubtreeIfNeeded()
        let operatorBitmap = try XCTUnwrap(operatorView.bitmapImageRepForCachingDisplay(in: operatorView.bounds))
        operatorView.cacheDisplay(in: operatorView.bounds, to: operatorBitmap)
        context.draw(try XCTUnwrap(operatorBitmap.cgImage), in: view.bounds)
        XCTAssertGreaterThan(bytes[(256 * 512 + 256) * 4], 150,
                             "embedded operator pane must retain the online preview")
    }

    @MainActor func testNewSessionRejectsQueuedDeliveryFromPreviousPipeline() async throws {
        let model = AppModel()
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = SessionProfile(targetName: "Sessions", subExposureSeconds: 20)
        let old = SessionPipeline(watchFolder: sandbox, profile: profile, rootDirectory: sandbox)
        let next = SessionPipeline(watchFolder: sandbox, profile: profile, rootDirectory: sandbox)
        model.wireCallbacks(to: old)
        let staleCallback = try XCTUnwrap(old.onDisplayUpdate)
        model.wireCallbacks(to: next)
        let image = try XCTUnwrap(AutoStretch.makeCGImage(AstroImage(width: 2, height: 2,
            channels: 1, pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: false)))
        staleCallback(DisplayDelivery(revision: 0, previewImage: image, broadcastImage: image,
            cleanMasterSubCount: 6, integrationSeconds: 120, previewIntegrationSeconds: 160, subExposureSeconds: 20, record: nil))
        let drained = expectation(description: "queued old callback processed")
        Task { @MainActor in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertNil(model.broadcastImage)
        XCTAssertNil(model.latestImage)
        XCTAssertNotEqual(model.liveRejectionStatus, .active(subs: 6))
    }

    @MainActor func testOlderRevisionCannotReplaceNewerPixelsOrCaption() throws {
        let state = DisplayPresentation()
        let session = UUID()
        state.begin(sessionID: session)
        let older = DisplayDelivery(revision: 1, previewImage: nil, broadcastImage: nil,
            cleanMasterSubCount: 3, integrationSeconds: 60, previewIntegrationSeconds: 80, subExposureSeconds: 20, record: nil)
        let newer = DisplayDelivery(revision: 2, previewImage: nil, broadcastImage: nil,
            cleanMasterSubCount: nil, integrationSeconds: 0, previewIntegrationSeconds: 0, subExposureSeconds: 20, record: nil)
        XCTAssertTrue(state.accept(newer, sessionID: session))
        XCTAssertFalse(state.accept(older, sessionID: session))
        XCTAssertNil(state.delivery?.cleanMasterSubCount)
        XCTAssertEqual(state.delivery?.revision, 2)
    }

    @MainActor func testSuccessfulRestackUpdatesDetachedDisplay() throws {
        let model = AppModel()
        model.isDetached = true
        let old = try XCTUnwrap(AutoStretch.makeCGImage(AstroImage(width: 2, height: 2,
            channels: 1, pixels: [0.9, 0.9, 0.9, 0.9], sourceIsLinear: false)))
        model.latestImage = old
        model.broadcastImage = old
        let report = RestackReport(master: AstroImage(width: 2, height: 2, channels: 1,
            pixels: [0.1, 0.1, 0.1, 0.1], sourceIsLinear: false), stackedCount: 2,
            skippedMissing: 0, skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        model.finishRestack(report, excludedCount: 1, writeResult: .init(ok: true, logMessage: nil),
                            sessionDir: nil, neutralize: false, subExposureSeconds: 60)
        XCTAssertNotEqual(model.broadcastImage?.dataProvider?.data as Data?, old.dataProvider?.data as Data?)
        XCTAssertEqual(model.latestImage?.dataProvider?.data as Data?, model.broadcastImage?.dataProvider?.data as Data?)
    }
}
