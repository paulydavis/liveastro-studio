import AppKit
import CoreGraphics
import XCTest
@testable import LiveAstroCore
@testable import LiveAstroStudio

@MainActor
final class NightModeControllerTests: XCTestCase {
    // Only the hardware boundary is faked: no suite may change the operator's display.
    func testEveryDisplayReceivesClampedTintAndOffRestoresOnlyAnActiveController() {
        let hardware = FakeNightDisplay()
        hardware.displays = [11, 22]
        let controller = makeController(hardware)
        controller.disable()
        XCTAssertEqual(hardware.restores, 0, "an inactive app must not reset another tint utility")
        controller.enable(level: 150)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(hardware.applied.map(\.0), [11, 22])
        XCTAssertEqual(hardware.applied.map(\.1), [1, 1])
        controller.disable()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(hardware.restores, 1)
        controller.reapplyIfActive()
        XCTAssertEqual(hardware.applied.count, 2, "late wake/timer must not turn tint back on")
    }

    func testPartialApplyFailureRestoresAndDoesNotAdvertiseProtection() {
        let hardware = FakeNightDisplay()
        hardware.displays = [11, 22]
        hardware.failedDisplay = 22
        let controller = makeController(hardware)
        var errors: [String] = []
        controller.onFailure = { errors.append($0) }
        controller.enable(level: 65)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(hardware.restores, 1)
        XCTAssertEqual(errors.count, 1)
        controller.reapplyIfActive()
        XCTAssertEqual(hardware.applied.count, 2, "failure must stop automatic reapplication")
    }

    func testEnumerationFailureAndNoDisplaysAreNotSuccessfulActivation() {
        for unavailable in [false, true] {
            let hardware = FakeNightDisplay()
            hardware.displays = []
            hardware.enumerationFails = unavailable
            let controller = makeController(hardware)
            var failures = 0
            controller.onFailure = { _ in failures += 1 }
            controller.enable(level: 65)
            XCTAssertFalse(controller.isActive)
            XCTAssertEqual(failures, 1)
            XCTAssertTrue(hardware.applied.isEmpty)
            XCTAssertEqual(hardware.restores, 0, "no display write took place")
        }
    }

    func testReapplyFailureRetiresPreviouslyActiveTint() {
        let hardware = FakeNightDisplay()
        let controller = makeController(hardware)
        controller.enable(level: 65)
        hardware.failedDisplay = 11
        var failures = 0
        controller.onFailure = { _ in failures += 1 }
        controller.reapplyIfActive()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(hardware.restores, 1)
    }

    func testSleepPausesWritesAndWakeReappliesUntilExplicitOff() {
        let hardware = FakeNightDisplay()
        let workspace = NotificationCenter()
        let controller = makeController(hardware, workspace: workspace)
        controller.enable(level: 42)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        controller.reapplyIfActive()
        XCTAssertTrue(controller.isActive, "sleep suspends rather than losing the user's request")
        XCTAssertEqual(hardware.applied.count, 1)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(hardware.applied.map(\.1), [0.42, 0.42])
        controller.disable()
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(hardware.applied.count, 2)
    }

    func testDisplayChangeAppliesToNewDisplaysAndQuitRestoresWithoutReactivation() {
        let hardware = FakeNightDisplay()
        let notifications = NotificationCenter()
        let controller = makeController(hardware, notifications: notifications)
        controller.enable(level: 65)
        hardware.displays.append(22)
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(hardware.applied.map(\.0), [11, 11, 22])
        notifications.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(hardware.restores, 1)
        controller.reapplyIfActive()
        XCTAssertEqual(hardware.applied.count, 3)
    }

    func testControllerReleaseRestoresAndDoesNotLeaveNotificationOwnership() {
        let hardware = FakeNightDisplay()
        let notifications = NotificationCenter()
        var controller: NightModeController? = makeController(hardware, notifications: notifications)
        weak let weakController = controller
        controller?.enable(level: 65)
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertEqual(hardware.restores, 1)
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(hardware.applied.count, 1)
    }

    func testNestedSleepNotificationsWaitForBothWakeEventsAndUseLatestLevel() {
        let hardware = FakeNightDisplay()
        let workspace = NotificationCenter()
        let controller = makeController(hardware, workspace: workspace)
        controller.enable(level: 65)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        controller.enable(level: 30)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(hardware.applied.count, 1, "system wake alone must not write a still-sleeping screen")
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(hardware.applied.map(\.1), [0.65, 0.30])
        controller.disable()
    }

    func testEnumerationFailureAfterActivationRestoresPreviousTint() {
        let hardware = FakeNightDisplay()
        let controller = makeController(hardware)
        controller.enable(level: 65)
        hardware.enumerationFails = true
        var errors: [String] = []
        controller.onFailure = { errors.append($0) }
        controller.reapplyIfActive()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(hardware.restores, 1)
        XCTAssertEqual(errors.count, 1)
    }

    func testActualTimerRestartsAfterSleepAndStopsAfterOff() async {
        let hardware = FakeNightDisplay()
        let workspace = NotificationCenter()
        let controller = makeController(hardware, workspace: workspace)
        defer { controller.disable() }
        controller.enable(level: 65)
        let firstTick = expectation(description: "real reapply timer fired")
        hardware.onApply = { firstTick.fulfill() }
        await fulfillment(of: [firstTick], timeout: 6)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        let sleepingWrite = expectation(description: "must not write while sleeping")
        sleepingWrite.isInverted = true
        hardware.onApply = { sleepingWrite.fulfill() }
        await fulfillment(of: [sleepingWrite], timeout: 2.3)
        hardware.onApply = nil
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        let wakeTick = expectation(description: "real timer restarted after wake")
        hardware.onApply = { wakeTick.fulfill() }
        await fulfillment(of: [wakeTick], timeout: 6)
        controller.disable()
        let lateWrite = expectation(description: "must not write after off")
        lateWrite.isInverted = true
        hardware.onApply = { lateWrite.fulfill() }
        await fulfillment(of: [lateWrite], timeout: 2.3)
    }

    func testTimerFailureTurnsModelOffAndStopsTimer() async throws {
        let (model, controller, hardware) = try modelFixture(store: true)
        model.nightVisionOn = true
        model.applyNightVision()
        hardware.failedDisplay = 11
        let failed = expectation(description: "real timer failure updates model")
        // Preserve the actual AppModel failure handler while observing completion.
        let modelHandler = controller.onFailure
        controller.onFailure = { message in modelHandler?(message); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 6)
        XCTAssertFalse(model.nightVisionOn)
        XCTAssertNotNil(model.errorMessage)
        let lateWrite = expectation(description: "failed timer must remain stopped")
        lateWrite.isInverted = true
        hardware.onApply = { lateWrite.fulfill() }
        await fulfillment(of: [lateWrite], timeout: 2.3)
    }

    func testStoreAndDirectModelsEnableTintWithoutChangingImageOrAdjustments() throws {
        for store in [true, false] {
            let (model, controller, hardware) = try modelFixture(store: store)
            let adjustments = model.staged.committed
            let image = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
            model.broadcastImage = image
            model.nightVisionOn = true
            model.applyNightVision()
            XCTAssertTrue(model.nightVisionOn)
            XCTAssertTrue(controller.isActive)
            XCTAssertEqual(hardware.applied.count, 1)
            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.broadcastImage === image)
            XCTAssertEqual(model.staged.committed, adjustments)
            model.nightVisionOn = false
            model.applyNightVision()
            XCTAssertEqual(hardware.restores, 1)
        }
    }

    func testLaterHardwareFailureReconcilesModelToggleAndExplainsFailure() throws {
        let (model, controller, hardware) = try modelFixture(store: true)
        model.nightVisionOn = true
        model.applyNightVision()
        XCTAssertTrue(model.nightVisionOn)
        hardware.failedDisplay = 11
        controller.reapplyIfActive()
        XCTAssertFalse(model.nightVisionOn)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(hardware.restores, 1)
    }

    private func makeController(_ hardware: FakeNightDisplay,
                                notifications: NotificationCenter = NotificationCenter(),
                                workspace: NotificationCenter = NotificationCenter()) -> NightModeController {
        NightModeController(display: hardware, notifications: notifications, workspaceNotifications: workspace)
    }

    private func modelFixture(store: Bool) throws -> (AppModel, NightModeController, FakeNightDisplay) {
        let suite = "NightModeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let hardware = FakeNightDisplay()
        let controller = makeController(hardware)
        let model = AppModel(userDefaults: defaults, calibrationLibrary: CalibrationLibrary(baseDirectory: root),
            configuration: StorePreviewConfiguration(bundleIdentifier: store ? "com.pauldavis.liveastrostudio.store-preview" : "test.direct", containerRoot: root),
            nightMode: controller)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        return (model, controller, hardware)
    }
}

private final class FakeNightDisplay: NightDisplayAccessing {
    var displays: [CGDirectDisplayID] = [11]
    var failedDisplay: CGDirectDisplayID?
    var enumerationFails = false
    var applied: [(CGDirectDisplayID, Float)] = []
    var restores = 0
    var onApply: (() -> Void)?
    func onlineDisplays() throws -> [CGDirectDisplayID] {
        if enumerationFails { throw CocoaError(.fileReadUnknown) }
        return displays
    }
    func apply(display: CGDirectDisplayID, redMax: Float) throws {
        applied.append((display, redMax))
        onApply?()
        if display == failedDisplay { throw CocoaError(.featureUnsupported) }
    }
    func restore() { restores += 1 }
}
