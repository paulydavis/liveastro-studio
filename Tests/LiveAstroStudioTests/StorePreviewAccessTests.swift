import XCTest
import Foundation
import Darwin
@testable import LiveAstroCore
@testable import LiveAstroStudio

@MainActor
final class StorePreviewAccessTests: XCTestCase {
    func testPreviewLibraryAddFailsOnUnreadableChildDespiteReadableSibling() async throws {
        let (model, backend, _, root) = try fixture()
        let source = try directory(root, "darks")
        try writeFITS(source.appendingPathComponent("a-readable.fit"))
        let denied = source.appendingPathComponent("b-denied.fit")
        try FITSWriter.float32(width: 8, height: 8, channels: 1, pixels: [Float](repeating: 0.9, count: 64)).write(to: denied)
        await assertAccessNotNil(await model.selectSourceFolder(source))
        XCTAssertEqual(chmod(denied.path, 0), 0)
        defer { chmod(denied.path, 0o600) }
        model.addMasterFromFolder(source, kind: .dark)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.calibrationBusy)
        XCTAssertTrue(model.libraryEntries.isEmpty, "an access failure must not produce a partial master")
        XCTAssertTrue(model.errorMessage?.contains("b-denied.fit") == true)
        XCTAssertFalse(model.log.contains { $0.contains("Calibration: added") })
        XCTAssertEqual(backend.balance(source), 0)
    }

    func testPreviewLibraryRebuildReadAndListingFailuresPreservePriorMasterAndIndex() async throws {
        let (model, backend, _, root) = try fixture()
        let source = try directory(root, "darks")
        try writeFITS(source.appendingPathComponent("a-readable.fit"))
        let denied = source.appendingPathComponent("b-denied.fit")
        try FITSWriter.float32(width: 8, height: 8, channels: 1, pixels: [Float](repeating: 0.9, count: 64)).write(to: denied)
        await assertAccessNotNil(await model.selectSourceFolder(source))
        model.addMasterFromFolder(source, kind: .dark)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        let frame = try XCTUnwrap(model.libraryEntries.first)
        let master = root.appendingPathComponent("container/library/" + frame.fileName)
        let index = root.appendingPathComponent("container/library/index.json")
        let masterBefore = try Data(contentsOf: master), indexBefore = try Data(contentsOf: index)
        XCTAssertEqual(chmod(denied.path, 0), 0)
        defer { chmod(denied.path, 0o600); chmod(source.path, 0o700) }
        model.rebuildMaster(frame.id)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.errorMessage?.contains("b-denied.fit") == true)
        XCTAssertEqual(try Data(contentsOf: master), masterBefore)
        XCTAssertEqual(try Data(contentsOf: index), indexBefore)
        model.errorMessage = nil
        XCTAssertEqual(chmod(source.path, 0), 0)
        model.rebuildMaster(frame.id)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.errorMessage, "denied enumeration must surface a folder-access error, not no frames")
        XCTAssertEqual(try Data(contentsOf: master), masterBefore)
        XCTAssertEqual(try Data(contentsOf: index), indexBefore)
        XCTAssertEqual(backend.balance(source), 0)
    }

    func testFailedMovedLibraryRebuildPersistsSiblingSourcesForRetryAndRelaunch() async throws {
        let (model, backend, defaults, root) = try fixture()
        let parent = try directory(root, "raws"), moved = root.appendingPathComponent("moved-raws")
        let darks = try directory(parent, "darks"), bias = try directory(parent, "bias")
        try writeFITS(darks.appendingPathComponent("dark.fit"))
        try writeFITS(bias.appendingPathComponent("bias.fit"))
        await assertAccessNotNil(await model.selectSourceFolder(parent))
        model.addMasterFromFolder(darks, kind: .dark)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        model.addMasterFromFolder(bias, kind: .bias)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        let dark = try XCTUnwrap(model.libraryEntries.first { $0.kind == .dark })
        let oldEntries = model.libraryEntries
        let master = root.appendingPathComponent("container/library/" + dark.fileName)
        let originalBytes = try Data(contentsOf: master)
        try FileManager.default.moveItem(at: parent, to: moved)
        backend.moves[parent.path] = moved
        let movedDarks = moved.appendingPathComponent("darks")
        try FileManager.default.removeItem(at: movedDarks.appendingPathComponent("dark.fit"))
        model.rebuildMaster(dark.id)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.log.contains { $0.contains("rebuild failed") })
        XCTAssertEqual(try Data(contentsOf: master), originalBytes)
        for old in oldEntries {
            var expected = old
            expected.sourcePath = moved.appendingPathComponent(old.kind == .dark ? "darks" : "bias").path
            XCTAssertEqual(model.libraryEntries.first { $0.id == old.id }, expected,
                           "only source identity may change when building fails")
        }
        await assertAccessThrows(try await model.acquireReadableLocation(darks), "do not authorize obsolete aliases")
        try writeFITS(movedDarks.appendingPathComponent("restored.fit"))
        model.rebuildMaster(dark.id)
        XCTAssertTrue(model.calibrationBusy)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.log.filter { $0 == "Calibration: rebuilt master." }.count, 1)
        let reopened = AppModel(userDefaults: defaults,
            calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("container/library")),
            configuration: config(root), bookmarkBackend: backend)
        reopened.refreshLibraryEntries()
        XCTAssertEqual(reopened.libraryEntries.count, 2)
        for entry in reopened.libraryEntries {
            reopened.rebuildMaster(entry.id)
            XCTAssertTrue(reopened.calibrationBusy)
            for _ in 0..<500 where reopened.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertNil(reopened.errorMessage)
        }
        XCTAssertEqual(reopened.log.filter { $0 == "Calibration: rebuilt master." }.count, 2)
        XCTAssertEqual(backend.balance(moved), 0)
    }

    func testUnrelatedDeniedLibraryGrantDoesNotBlockSelectedRebuild() async throws {
        let (model, backend, _, root) = try fixture()
        let selected = try directory(root, "darks"), unrelated = try directory(root, "bias")
        for folder in [selected, unrelated] {
            try writeFITS(folder.appendingPathComponent("raw.fit"))
            await assertAccessNotNil(await model.selectSourceFolder(folder))
            model.addMasterFromFolder(folder, kind: folder == selected ? .dark : .bias)
            for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let dark = try XCTUnwrap(model.libraryEntries.first { $0.kind == .dark })
        let bias = try XCTUnwrap(model.libraryEntries.first { $0.kind == .bias })
        backend.denied = unrelated
        try writeFITS(selected.appendingPathComponent("second.fit"))
        model.rebuildMaster(dark.id)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.libraryEntries.first { $0.id == dark.id }?.frameCount, 2)
        XCTAssertEqual(model.libraryEntries.first { $0.id == bias.id }, bias)
        XCTAssertEqual(backend.balance(selected), 0)
        XCTAssertEqual(backend.balance(unrelated), 0)
    }

    func testNativeNRUsesRetainedLiveSessionAfterOutputChangeAndWorkerOutlivesContext() async throws {
        let gate = GatedNativeProcessor()
        let (model, backend, _, root) = try fixture(makeNativeProcessor: { gate })
        let input = try directory(root, "input"), realOutput = try directory(root, "output"), future = try directory(root, "future")
        let output = root.appendingPathComponent("output-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: realOutput)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.sourceMode = .nativeStack
        model.startSession()
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.isRunning)
        model.endSession()
        for _ in 0..<1000 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        let session = try XCTUnwrap(model.lastSessionDirectory)
        // Empty live End supplies the real ownership context; a small master fixture
        // avoids unrelated watcher/stack quality behavior in this post-processing test.
        let master = session.appendingPathComponent("master.fit")
        try writeFITS(master)
        await assertAccessTrue(await model.selectLocation(future, key: "output"))
        model.processorBackend = .nativeDenoise
        model.errorMessage = nil
        model.importer.processMaster(sessionDirectory: session)
        for _ in 0..<500 where model.importer.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("master_processed.fit").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: future.path).isEmpty)
        let unrelated = try directory(output, "unrelated-session")
        try writeFITS(unrelated.appendingPathComponent("master.fit"))
        model.importer.processMaster(sessionDirectory: unrelated)
        try await waitForAccess { !model.importer.isProcessing }
        XCTAssertNotNil(model.errorMessage, "retained owner only authorizes the exact completed session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("master_processed.fit").path))
        model.errorMessage = nil
        await assertAccessNotNil(await model.selectSourceFolder(unrelated))
        model.importer.processMaster(sessionDirectory: unrelated)
        for _ in 0..<500 where model.importer.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("master_processed.fit").path))
        XCTAssertEqual(backend.balance(unrelated), 0, "an unrelated directory uses an independent short-lived grant")
        let processed = session.appendingPathComponent("master_processed.fit")
        try FileManager.default.removeItem(at: processed)
        gate.parkNextCall()
        defer { gate.release.signal() }
        model.importer.processMaster(sessionDirectory: session)
        guard model.importer.isProcessing else { return XCTFail("NR must acquire the retained context") }
        for _ in 0..<500 where !gate.hasEntered { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(gate.hasEntered)
        // New admitted work retires the app context while its native processor
        // is parked. The gate owns no leases and delegates real NR when released.
        model.importer.importSubs(from: input)
        for _ in 0..<500 where model.importer.isImporting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(backend.balance(output), 1, "the NR reader owns its own captured operation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: processed.path))
        model.errorMessage = nil // clear the deliberately empty replacement import's no-match message
        gate.release.signal()
        for _ in 0..<500 where model.importer.isProcessing || backend.balance(output) != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.importer.isProcessing)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: processed.path))
        XCTAssertEqual(backend.balance(output), 0)
    }

    func testNativeNRUsesFinishedImportContextAfterFutureOutputChange() async throws {
        let gate = GatedNativeProcessor()
        let (model, backend, _, root) = try fixture(makeNativeProcessor: { gate })
        let input = try directory(root, "input"), output = try directory(root, "output"), future = try directory(root, "future")
        try writeStarField(input.appendingPathComponent("Light_001.fit"))
        model.fileNamePrefix = "Light_"
        await assertAccessNotNil(await model.selectSourceFolder(input))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.importer.importSubs(from: input)
        for _ in 0..<1500 where model.importer.isImporting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.importer.isImporting)
        XCTAssertNil(model.errorMessage)
        let session = try XCTUnwrap(model.lastSessionDirectory)
        XCTAssertTrue(session.path.hasPrefix(output.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("master.fit").path))
        await assertAccessTrue(await model.selectLocation(future, key: "output"))
        // A denied preparation must not retire the successful import context.
        model.importer.importSubs(from: root.appendingPathComponent("not-authorized"))
        try await waitForAccess { !model.importer.isImporting }
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        // Cancellation of a real metadata read likewise keeps the old context.
        let cancelledInput = try directory(root, "cancelled-input")
        let fifo = cancelledInput.appendingPathComponent("Light_blocked.fit")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        await assertAccessNotNil(await model.selectSourceFolder(cancelledInput))
        model.importer.importSubs(from: cancelledInput)
        var writer: Int32 = -1
        defer { if writer >= 0 { Darwin.close(writer) } }
        for _ in 0..<500 where writer < 0 {
            writer = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK)
            if writer < 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        XCTAssertGreaterThanOrEqual(writer, 0)
        model.importer.cancelImport()
        XCTAssertEqual(backend.balance(output), 1)
        Darwin.close(writer); writer = -1
        for _ in 0..<500 where backend.balance(cancelledInput) != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(backend.balance(cancelledInput), 0)
        XCTAssertNil(model.errorMessage)
        model.processorBackend = .nativeDenoise
        gate.parkNextCall()
        defer { gate.release.signal() }
        model.importer.processMaster(sessionDirectory: session)
        for _ in 0..<500 where !gate.hasEntered { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(gate.hasEntered)
        let empty = try directory(root, "next-empty-import")
        await assertAccessNotNil(await model.selectSourceFolder(empty))
        model.importer.importSubs(from: empty)
        for _ in 0..<500 where model.importer.isImporting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.importer.isImporting)
        XCTAssertEqual(backend.balance(output), 1, "NR keeps the finished import owner after context retirement")
        model.errorMessage = nil
        gate.release.signal()
        for _ in 0..<1000 where model.importer.isProcessing || backend.balance(output) != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("master_processed.fit").path))
        for child in try FileManager.default.contentsOfDirectory(at: future, includingPropertiesForKeys: nil) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent("master_processed.fit").path))
        }
        XCTAssertEqual(backend.balance(output), 0)
    }

    private func writeStarField(_ url: URL) throws {
        let size = 512
        var pixels = [Float](repeating: 0.05, count: size * size)
        for i in 0..<24 {
            let cx = (i * 47 + 13) % 480 + 16, cy = (i * 83 + 29) % 480 + 16
            for y in (cy - 8)...(cy + 8) {
                for x in (cx - 8)...(cx + 8) {
                    let dx = Double(x - cx), dy = Double(y - cy)
                    pixels[y * size + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / 18))
                }
            }
        }
        try FITSWriter.float32(width: size, height: size, channels: 1, pixels: pixels).write(to: url)
    }

    func testRelayStopDoesNotRetireUnownedDirectDiscoveryState() async throws {
        let (_, _, _, root) = try fixture()
        let controller = LiveSourceController(surface: AppSurface(log: { _ in }, presentError: { _ in },
            isSessionRunning: { false }), relayRoot: root.appendingPathComponent("relay"))
        // Auto discovery owns this public controller state, not the newly added
        // manual-preparation task. No /Volumes scan is needed for this boundary.
        controller.isDetecting = true
        controller.stopRelay()
        XCTAssertTrue(controller.isDetecting)
    }
    func testMovedParentResolvesBothCalibrationChildrenAcrossOperationAndRelaunch() async throws {
        let (model, backend, defaults, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        let original = try directory(root, "masters"), moved = root.appendingPathComponent("moved-masters")
        try writeFITS(original.appendingPathComponent("dark.fit"))
        try writeFITS(original.appendingPathComponent("flat.fit"))
        await assertAccessNotNil(await model.selectSourceFolder(original))
        model.calibration.darkPath = original.appendingPathComponent("dark.fit").path
        model.calibration.flatPath = original.appendingPathComponent("flat.fit").path
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.saveSettings()
        try FileManager.default.moveItem(at: original, to: moved)
        backend.moves[original.path] = moved
        await assertAccessEqual(try await model.acquireOperationAccess(input: input).flatPath, moved.appendingPathComponent("flat.fit").path)
        await assertAccessEqual(try await model.acquireOperationAccess(input: input).darkPath, moved.appendingPathComponent("dark.fit").path)
        let reopened = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        for _ in 0..<500 where reopened.isRestoringLocationAccess { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNil(reopened.errorMessage)
        await assertAccessEqual(try await reopened.acquireOperationAccess(input: input).flatPath, moved.appendingPathComponent("flat.fit").path)
        await assertAccessThrows(try await reopened.acquireReadableLocation(original.appendingPathComponent("dark.fit")),
                             "a later unrelated acquisition must not authorize the obsolete root")
        XCTAssertEqual(backend.balance(moved), 0)
        XCTAssertEqual(backend.balance(output), 0)
    }

    func testFreshRestoreResolvesBothChildrenOfMovedCalibrationParent() async throws {
        let (model, backend, defaults, root) = try fixture()
        let original = try directory(root, "masters"), moved = root.appendingPathComponent("moved-masters")
        try writeFITS(original.appendingPathComponent("dark.fit"))
        try writeFITS(original.appendingPathComponent("flat.fit"))
        await assertAccessNotNil(await model.selectSourceFolder(original))
        model.calibration.darkPath = original.appendingPathComponent("dark.fit").path
        model.calibration.flatPath = original.appendingPathComponent("flat.fit").path
        model.saveSettings()
        try FileManager.default.moveItem(at: original, to: moved)
        backend.moves[original.path] = moved
        let reopened = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        for _ in 0..<500 where reopened.isRestoringLocationAccess { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.calibration.darkPath, moved.appendingPathComponent("dark.fit").path)
        XCTAssertEqual(reopened.calibration.flatPath, moved.appendingPathComponent("flat.fit").path)
        XCTAssertEqual(CalibrationStore.load(defaults).flatPath, moved.appendingPathComponent("flat.fit").path)
        XCTAssertEqual(backend.balance(moved), 0)
    }
    func testAsynchronousCalibrationPreparationPublishesAppliedFlatStatus() async throws {
        let (model, _, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output"), flats = try directory(root, "flats")
        try writeFITS(input.appendingPathComponent("Light_old.fit"))
        try writeFITS(flats.appendingPathComponent("flat.fit"))
        await model.setCalibrationFolder(flats, darkFlats: false)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.sourceMode = .nativeStack
        model.startSession()
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 1_000_000) }
        model.resolvePendingSessionStart(.stackExistingAndNew)
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(model.isRunning)
        XCTAssertTrue(model.calibrationStatus.contains("flat"))
        model.endSession()
        for _ in 0..<500 where model.isRunning { try await Task.sleep(nanoseconds: 1_000_000) }
    }
    func testDemoWaitsForAsynchronousStartAndRestoresSettingsOnCancellation() async throws {
        let (_, backend, defaults, root) = try fixture()
        let output = try directory(root, "output")
        let gate = GatedAvailability(target: output)
        let model = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend, locationAvailability: gate)
        model.targetName = "Original target"
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.startDemoSession()
        try await waitForAccess { gate.hasEntered }
        XCTAssertTrue(model.isPreparingSessionInput)
        XCTAssertEqual(model.targetName, "Demo Nebula")
        for _ in 0..<500 where !gate.hasEntered { try await Task.sleep(nanoseconds: 1_000_000) }
        model.cancelSessionInputPreparation()
        XCTAssertEqual(model.targetName, "Original target")
        gate.release.signal()
        for _ in 0..<500 where backend.balance(output) != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(backend.balance(output), 0)
        XCTAssertFalse(model.isRunning)
    }

    func testManualLiveAvailabilityCancellationDoesNotStartAfterParkedCheckReturns() async throws {
        let (_, backend, defaults, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        let gate = GatedAvailability(target: input)
        let model = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend, locationAvailability: gate)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.liveSource.startWatchFolderLive(source: input)
        for _ in 0..<500 where !gate.hasEntered { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(gate.ranOnMain)
        model.liveSource.stopRelay()
        XCTAssertFalse(model.liveSource.isDetecting)
        XCTAssertEqual(backend.balance(input), 1)
        gate.release.signal()
        for _ in 0..<500 where backend.balance(input) != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(backend.balance(input), 0)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.errorMessage)
    }

    func testOldCalibrationFailureCannotEndNewPresentation() async throws {
        let (model, _, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        let old = SessionPipeline(watchFolder: input, profile: model.profile, rootDirectory: output,
                                  catalogURL: config(root).catalogURL)
        model.wireCallbacks(to: old)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.sourceMode = .nativeStack
        model.startSession()
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(model.isRunning)
        old.onCalibrationFailure?(CalibrationReadError(url: input, underlying: CocoaError(.fileReadNoPermission)))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.errorMessage)
        model.endSession()
        for _ in 0..<500 where model.isRunning { try await Task.sleep(nanoseconds: 1_000_000) }
    }
    func testAvailabilityStartIsOffMainAndCancellationKeepsParkedWorkerAccess() async throws {
        let (_, backend, defaults, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        let gate = GatedAvailability(target: input)
        let model = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend, locationAvailability: gate)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.sourceMode = .nativeStack
        var results: [Bool] = []
        model.startSession { results.append($0) }
        for _ in 0..<500 where !gate.hasEntered { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(gate.ranOnMain)
        XCTAssertTrue(model.isPreparingSessionInput)
        model.cancelSessionInputPreparation()
        XCTAssertEqual(results, [false])
        XCTAssertEqual(backend.balance(input), 1)
        gate.release.signal()
        for _ in 0..<500 where backend.balance(input) != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(backend.balance(input), 0)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(results, [false])
    }

    func testAvailabilityImportIsOffMainAndCancellationKeepsParkedWorkerAccess() async throws {
        let (_, backend, defaults, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        let gate = GatedAvailability(target: input)
        let model = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend, locationAvailability: gate)
        await assertAccessNotNil(await model.selectSourceFolder(input))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.importer.importSubs(from: input)
        for _ in 0..<500 where !gate.hasEntered { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(gate.ranOnMain)
        model.importer.cancelImport()
        XCTAssertFalse(model.importer.isImporting)
        XCTAssertEqual(backend.balance(input), 1)
        gate.release.signal()
        for _ in 0..<500 where backend.balance(input) != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(backend.balance(input), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    func testAvailabilityRestoreIsOffMainAndDoesNotOverwriteReselection() async throws {
        let (initial, backend, defaults, root) = try fixture()
        let input = try directory(root, "input"), replacement = try directory(root, "replacement")
        await assertAccessTrue(await initial.selectLocation(input, key: "capture"))
        initial.saveSettings()
        let gate = GatedAvailability(target: input)
        let model = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend, locationAvailability: gate)
        XCTAssertEqual(model.watchFolder?.path, input.path)
        for _ in 0..<500 where !gate.hasEntered { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(gate.ranOnMain)
        XCTAssertEqual(backend.balance(input), 1)
        await assertAccessTrue(await model.selectLocation(replacement, key: "capture"))
        try FileManager.default.removeItem(at: input)
        gate.release.signal()
        for _ in 0..<500 where backend.balance(input) != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(model.watchFolder?.path, replacement.path)
        XCTAssertNil(model.errorMessage, "superseded restore validation must not publish its old failure")
    }
    func testUnreadableFlatChildFailsAfterPendingQuestionInsteadOfStartingUncalibrated() async throws {
        let (model, _, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output"), flats = try directory(root, "flats")
        try writeFITS(input.appendingPathComponent("Light_old.fit"))
        let child = flats.appendingPathComponent("flat.fit")
        try writeFITS(child)
        await model.setCalibrationFolder(flats, darkFlats: false)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.sourceMode = .nativeStack
        var result: Bool?
        model.startSession { result = $0 }
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.pendingSessionStart)
        XCTAssertEqual(chmod(child.path, 0), 0)
        defer { chmod(child.path, 0o600) }
        model.resolvePendingSessionStart(.stackExistingAndNew)
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(result, false)
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.errorMessage)
        if model.isRunning { model.endSession() }
        for _ in 0..<500 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testFirstSubCalibrationLossFailsBeforeProcessingAnyFrame() async throws {
        let (model, _, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output"), flats = try directory(root, "flats")
        try writeFITS(flats.appendingPathComponent("flat.fit"))
        await model.setCalibrationFolder(flats, darkFlats: false)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.sourceMode = .nativeStack
        model.startSession()
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.isRunning)
        if case .waitingForFirstSub = model.sessionInputStatus {} else {
            XCTFail("off-main calibration preparation must preserve the empty-input waiting status")
        }
        try FileManager.default.removeItem(at: flats)
        try writeFITS(input.appendingPathComponent("Light_new.fit"))
        for _ in 0..<600 where model.errorMessage == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.acceptedCount, 0)
        XCTAssertEqual(model.rejectedCount, 0, "calibration failure must precede engine processing, not just acceptance")
        if model.isRunning { model.endSession() }
        for _ in 0..<500 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.replayURL)
        XCTAssertFalse(model.isRunning, "latched fatal calibration failure must not require retrying an impossible End")
        if case .failed = model.sessionInputStatus {} else {
            XCTFail("a fatal calibration failure must not continue displaying waiting for input")
        }
        await model.setCalibrationFolder(nil, darkFlats: false)
        try FileManager.default.removeItem(at: input.appendingPathComponent("Light_new.fit"))
        model.errorMessage = nil
        model.startSession()
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(model.isRunning, "reselection and a new session are admitted without relaunch")
        model.endSession()
        for _ in 0..<500 where model.isRunning { try await Task.sleep(nanoseconds: 1_000_000) }
    }

    func testImportMasterLossAfterMetadataPreparationFailsWithoutOutput() async throws {
        let (model, _, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output"), masters = try directory(root, "masters")
        let master = masters.appendingPathComponent("dark.fit")
        try writeFITS(master)
        await assertAccessNotNil(await model.selectSourceFolder(masters))
        model.calibration.darkPath = master.path
        let fifo = input.appendingPathComponent("Light_blocked.fit")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        await assertAccessNotNil(await model.selectSourceFolder(input))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.importer.importSubs(from: input)
        var writer: Int32 = -1
        for _ in 0..<500 where writer < 0 {
            writer = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK)
            if writer < 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        defer { if writer >= 0 { Darwin.close(writer) } }
        XCTAssertGreaterThanOrEqual(writer, 0)
        try FileManager.default.removeItem(at: master)
        try FileManager.default.removeItem(at: fifo)
        try writeFITS(input.appendingPathComponent("Light_real.fit"))
        Darwin.close(writer); writer = -1
        for _ in 0..<1000 where model.importer.isImporting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.importer.isImporting)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    func testManualLiveMetadataPreparationPinsFutureSessionDestination() async throws {
        let (model, backend, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output"), future = try directory(root, "future")
        let fifo = input.appendingPathComponent("Light_blocked.fit")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.liveSource.startWatchFolderLive(source: input)
        var writer: Int32 = -1
        for _ in 0..<500 where writer < 0 {
            writer = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK)
            if writer < 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        defer { if writer >= 0 { Darwin.close(writer) }; model.liveSource.stopRelay() }
        XCTAssertGreaterThanOrEqual(writer, 0)
        await assertAccessTrue(await model.selectLocation(future, key: "output"))
        XCTAssertEqual(backend.balance(output), 1)
        try FileManager.default.removeItem(at: fifo)
        Darwin.close(writer); writer = -1
        for _ in 0..<1000 where model.liveSource.isDetecting || model.hasPendingSessionStart { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.isRunning, model.errorMessage ?? "manual live start failed")
        model.endSession()
        for _ in 0..<1000 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.lastSessionDirectory?.path.hasPrefix(output.path + "/") == true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: future.path).isEmpty)
    }

    func testStoppedSourceKeepsAccessInItsAlreadyRunningPull() async throws {
        let (model, backend, _, root) = try fixture()
        let input = try directory(root, "input")
        try writeFITS(input.appendingPathComponent("Light_test.fit"))
        await assertAccessNotNil(await model.selectSourceFolder(input))
        var access: FileAccessLease? = try await model.acquireReadableLocation(input)
        var source: FolderFrameSource? = FolderFrameSource(folder: input, mode: .importOnce, accessLifetime: access)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        source?.onActivity = { event in
            if case .beginFrameRead = event { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        }
        try source?.start()
        let read = startPull(try XCTUnwrap(source))
        access = nil
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        source?.stop()
        source = nil
        read.cancel()
        XCTAssertEqual(backend.balance(input), 1)
        release.signal()
        _ = await read.value
        for _ in 0..<500 where backend.balance(input) != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(backend.balance(input), 0)
    }

    private func startPull(_ source: FolderFrameSource) -> Task<Bool, Never> {
        let frames = source.frames
        return Task.detached {
            var iterator = frames.makeAsyncIterator()
            return await iterator.next() != nil
        }
    }

    func testWatcherStopDoesNotReleaseAccessFromParkedContentRead() async throws {
        let (model, backend, _, root) = try fixture()
        let input = try directory(root, "input")
        await assertAccessNotNil(await model.selectSourceFolder(input))
        var access: FileAccessLease? = try await model.acquireReadableLocation(input)
        var watcher: StackFileWatcher? = StackFileWatcher(folder: input, quietPeriod: 0.01, pollInterval: 0.02,
            digestPolicy: .immutableAfterPublish, accessLifetime: access)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        watcher?.beforeContentReadForTesting = { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        defer { release.signal(); watcher?.stop() }
        access = nil
        try watcher?.start()
        try writeFITS(input.appendingPathComponent("Light_test.fit"))
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        watcher?.stop(timeout: 0.01)
        watcher = nil
        XCTAssertEqual(backend.balance(input), 1)
        release.signal()
        for _ in 0..<500 where backend.balance(input) != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(backend.balance(input), 0)
    }

    func testTimedOutRefinerKeepsAccessUntilActualReadReturns() async throws {
        let (model, backend, _, root) = try fixture()
        let input = try directory(root, "input"), file = input.appendingPathComponent("Light_test.fit")
        try writeFITS(file)
        await assertAccessNotNil(await model.selectSourceFolder(input))
        var access: FileAccessLease? = try await model.acquireReadableLocation(input)
        let loader = GatedRealFrameLoader()
        var refiner: GlobalRefiner? = GlobalRefiner(loader: loader, onLog: { _ in }, accessLifetime: access)
        access = nil
        let registration = SubRegistration(subIndex: 0, contentDigest: nil, relayURL: file, stackGeneration: 0,
            referenceIdentity: nil, transform: .identity, effectiveScale: 1, weight: 1, leveling: nil,
            exposure: FrameExposure(metadata: nil, fallback: 30))
        let result = refiner?.refine(survivors: [registration], currentGeneration: 0, kappa: 3, minSubs: 1,
            maxSampleBytes: 1_000_000, deadline: .now() + 0.05, isCancelled: { false })
        XCTAssertNil(result)
        XCTAssertTrue(loader.hasEntered)
        refiner = nil
        XCTAssertEqual(backend.balance(input), 1, "the timed-out read owns its permission independently")
        loader.release.signal()
        for _ in 0..<500 where backend.balance(input) != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(backend.balance(input), 0)
    }

    func testCompletionCancelRetryWritesCapturedOutputThenImportRetiresAccess() async throws {
        let (model, backend, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output"), future = try directory(root, "future")
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.sourceMode = .nativeStack
        model.startSession()
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.isRunning)
        model.endSession()
        for _ in 0..<1000 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isRunning)
        model.errorMessage = nil // empty-session replay has no frames; that is unrelated to completion

        let manager = SessionManager(rootDirectory: output)
        let dir = try manager.startSession(profile: SessionProfile(targetName: "Incomplete", subExposureSeconds: 30), masterExpected: true)
        let status = CleanStackStatus(expectedCount: 6, savedCount: 5,
            expectedExposure: .estimated(count: 6, seconds: 30), savedExposure: .estimated(count: 5, seconds: 30),
            savedClean: true, reason: .timedOut)
        try manager.endSession(finalization: .init(masterOutcome: .written, stackFrameCount: 6,
            sessionAcceptedCount: 6, sessionRejectedCount: 0, exposure: status.savedExposure, cleanStackStatus: status))
        try writeFITS(dir.appendingPathComponent("master.fit"))
        let before = try Data(contentsOf: dir.appendingPathComponent("master.fit"))
        let registrations = try (0..<6).map { index in
            let file = input.appendingPathComponent("\(index).fit")
            try writeFITS(file)
            return SubRegistration(subIndex: index, contentDigest: nil, relayURL: file, stackGeneration: 0,
                referenceIdentity: nil, transform: .identity, effectiveScale: 1, weight: 1, leveling: nil,
                exposure: FrameExposure(metadata: nil, fallback: 30))
        }
        let loader = GatedRealFrameLoader()
        let request = try CleanStackCompletion(directory: dir, survivors: registrations, generation: 0,
            kappa: 3, budget: 1_000_000, minSubs: 5, loader: loader, metadata: nil,
            neutralize: false, fallbackSeconds: 30, status: status)
        model.presentCleanStackCompletion(request, status: status)
        await assertAccessTrue(await model.selectLocation(future, key: "output"))
        backend.denied = future
        model.importer.importSubs(from: input)
        try await waitForAccess { !model.importer.isImporting }
        XCTAssertFalse(model.importer.isImporting)
        XCTAssertTrue(model.canFinishCleanStack, "denied future output must not retire the old completion")
        XCTAssertEqual(backend.balance(output), 1)
        backend.denied = nil
        model.errorMessage = nil
        model.finishCleanStack()
        for _ in 0..<500 where !loader.hasEntered { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(loader.hasEntered)
        model.cancelCleanStack()
        XCTAssertEqual(backend.balance(input), 1)
        XCTAssertEqual(backend.balance(output), 1)
        loader.release.signal()
        for _ in 0..<500 where model.isRestacking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.canFinishCleanStack)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("master.fit")), before)
        model.finishCleanStack()
        for _ in 0..<500 where model.isRestacking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.cleanStackStatus?.savedCount, 6)
        let header = try FITSReader.readHeader(Data(contentsOf: dir.appendingPathComponent("master.fit")))
        XCTAssertEqual(header.keywords["STACKCNT"].flatMap(Int.init), 6)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: future.path).isEmpty)
        XCTAssertEqual(backend.balance(output), 1)
        model.importer.importSubs(from: input)
        for _ in 0..<1000 where model.importer.isImporting || backend.balance(output) != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(backend.balance(output), 0)
        XCTAssertEqual(backend.balance(input), 0)
    }

    func testPipelineReloadKeepsItsExplicitCatalogLocation() async throws {
        let (_, _, _, root) = try fixture()
        let catalog = root.appendingPathComponent("chosen-catalog.bin")
        try StarCatalog.encode([CatalogStar(ra: 10, dec: 20, mag: 3)]).write(to: catalog)
        let pipeline = SessionPipeline(watchFolder: root, profile: SessionProfile(targetName: "Catalog"),
            rootDirectory: root, catalogURL: catalog)
        XCTAssertEqual(pipeline.plateSolveCatalog?.count, 1)
        try StarCatalog.encode([CatalogStar(ra: 10, dec: 20, mag: 3), CatalogStar(ra: 30, dec: 40, mag: 4)]).write(to: catalog)
        pipeline.reloadCatalog()
        XCTAssertEqual(pipeline.plateSolveCatalog?.count, 2)
    }

    func testCancelledImportKeepsGrantWhileRealMetadataReadIsBlocked() async throws {
        let (model, backend, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        let fifo = input.appendingPathComponent("Light_blocked.fit")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        await assertAccessNotNil(await model.selectSourceFolder(input))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.importer.importSubs(from: input)
        var writer: Int32 = -1
        for _ in 0..<500 where writer < 0 {
            writer = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK)
            if writer < 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        defer { if writer >= 0 { Darwin.close(writer) } }
        XCTAssertGreaterThanOrEqual(writer, 0, "real metadata reader must have opened the FIFO")
        model.importer.cancelImport()
        XCTAssertFalse(model.importer.isImporting)
        XCTAssertEqual(backend.balance(input), 1, "cancel must not revoke a blocked filesystem worker")
        XCTAssertEqual(backend.balance(output), 1)
        Darwin.close(writer); writer = -1
        for _ in 0..<500 where backend.balance(input) != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(backend.balance(input), 0)
        XCTAssertEqual(backend.balance(output), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    func testRealStartEndPinsOutputAndRetainsPostSessionPermissionsUntilImport() async throws {
        let (model, backend, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output"), future = try directory(root, "future")
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.sourceMode = .nativeStack
        model.startSession()
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.isRunning, model.errorMessage ?? "start failed")
        XCTAssertEqual(backend.balance(input), 1)
        await assertAccessTrue(await model.selectLocation(future, key: "output"))
        model.endSession()
        for _ in 0..<1000 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.lastSessionDirectory?.path.hasPrefix(output.path + "/") == true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: future.path).isEmpty)
        XCTAssertEqual(backend.balance(input), 1)
        XCTAssertEqual(backend.balance(output), 1)
        // A real new import retires the old post-session source/output context.
        model.importer.importSubs(from: input)
        for _ in 0..<1000 where model.importer.isImporting || backend.balance(output) != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(backend.balance(input), 0)
        XCTAssertEqual(backend.balance(output), 0)
    }

    func testDirectConfigurationKeepsDefaultsAndNeedsNoBookmark() async throws {
        let (_, backend, defaults, root) = try fixture()
        let direct = AppModel(userDefaults: defaults, calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("direct-library")),
                              configuration: StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio", containerRoot: root), bookmarkBackend: backend)
        let expected = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveAstro")
        XCTAssertFalse(direct.isStorePreview)
        XCTAssertEqual(direct.liveAstroRoot.path, expected.path)
        let input = try directory(root, "bare-input")
        let access = try await direct.acquireOperationAccess(input: input)
        XCTAssertEqual(access.input.path, input.path)
        XCTAssertEqual(access.output.path, expected.path)
        XCTAssertEqual(backend.balance(input), 0)
    }

    func testSharedMovedSourceSessionFirstUpdatesLibraryAndDarkFlats() async throws {
        try await assertSharedMovedSource(rebuildFirst: false)
    }

    func testSharedMovedSourceRebuildFirstUpdatesLibraryAndDarkFlats() async throws {
        try await assertSharedMovedSource(rebuildFirst: true)
    }

    func testFailedMovedLibraryPersistenceKeepsOldGrantForRetry() async throws {
        let (model, backend, defaults, root) = try fixture()
        let source = try directory(root, "shared-bias"), moved = root.appendingPathComponent("moved-bias")
        let input = try directory(root, "input"), output = try directory(root, "output")
        try writeFITS(source.appendingPathComponent("bias.fit"))
        await model.setCalibrationFolder(source, darkFlats: true)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.addMasterFromFolder(source, kind: .bias)
        try await waitForAccess { !model.calibrationBusy }
        XCTAssertEqual(model.libraryEntries.count, 1)
        let before = try XCTUnwrap(defaults.data(forKey: AuthorizedLocations.defaultsKey))
        try FileManager.default.moveItem(at: source, to: moved)
        backend.moves[source.path] = moved
        let library = root.appendingPathComponent("container/library")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        await assertAccessThrows(try await model.acquireOperationAccess(input: input))
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), before)
        XCTAssertEqual(model.sessionDarkFlatsFolder?.path, source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path)
        await assertAccessEqual(try await model.acquireOperationAccess(input: input).darkFlats?.path, moved.path)
        XCTAssertEqual(model.libraryEntries.first?.sourcePath, moved.path)
        let reopened = AppModel(userDefaults: defaults,
                                calibrationLibrary: CalibrationLibrary(baseDirectory: library),
                                configuration: config(root), bookmarkBackend: backend)
        try await waitForAccess { !reopened.isRestoringLocationAccess }
        await assertAccessEqual(try await reopened.acquireOperationAccess(input: input).darkFlats?.path, moved.path)
    }

    func testRemovedLibraryEntryIsNotRecreatedByPreparedRelocation() async throws {
        let (model, backend, _, root) = try fixture()
        let source = try directory(root, "shared-bias"), moved = root.appendingPathComponent("moved-bias")
        try writeFITS(source.appendingPathComponent("bias.fit"))
        await model.setCalibrationFolder(source, darkFlats: true)
        model.addMasterFromFolder(source, kind: .bias)
        try await waitForAccess { !model.calibrationBusy }
        let entry = try XCTUnwrap(model.libraryEntries.first)
        let references = model.captureLocationReferences()
        try FileManager.default.moveItem(at: source, to: moved)
        backend.moves[source.path] = moved
        let prepared = try await model.authorizedLocations.prepare([.url(source)])
        model.removeMaster(entry.id)
        let changes = try model.reconcileLocationReferences(references, prepared: prepared)
        try model.authorizedLocations.commit(changes)
        XCTAssertTrue(model.calibrationLibrary.all().isEmpty)
        XCTAssertEqual(model.sessionDarkFlatsFolder?.path, moved.path)
    }

    func testReselectedSessionFolderIsNotOverwrittenByPreparedRelocation() async throws {
        let (model, backend, _, root) = try fixture()
        let source = try directory(root, "old"), moved = root.appendingPathComponent("moved")
        let new = try directory(root, "new-choice")
        await model.setCalibrationFolder(source, darkFlats: true)
        let references = model.captureLocationReferences()
        try FileManager.default.moveItem(at: source, to: moved)
        backend.moves[source.path] = moved
        let prepared = try await model.authorizedLocations.prepare([.url(source)])
        await model.setCalibrationFolder(new, darkFlats: true)
        let changes = try model.reconcileLocationReferences(references, prepared: prepared)
        try model.authorizedLocations.commit(changes)
        XCTAssertEqual(model.sessionDarkFlatsFolder?.path, new.path)
    }

    func testLibraryReferenceAddedDuringResolutionDefersRenewalUntilNextBatch() async throws {
        let (model, backend, defaults, root) = try fixture()
        let old = try directory(root, "old"), moved = root.appendingPathComponent("moved")
        try writeFITS(old.appendingPathComponent("bias.fit"))
        await model.setCalibrationFolder(old, darkFlats: true)
        let references = model.captureLocationReferences()
        let before = defaults.data(forKey: AuthorizedLocations.defaultsKey)
        try FileManager.default.moveItem(at: old, to: moved)
        backend.moves[old.path] = moved
        let prepared = try await model.authorizedLocations.prepare([.url(old)])
        let frame = try model.calibrationLibrary.add(kind: .bias, camera: "Camera", gain: nil,
                                                     exposureSeconds: nil, setTempC: nil, binning: nil,
                                                     fitsURLs: [moved.appendingPathComponent("bias.fit")], sourceDirectory: old)
        let changes = try model.reconcileLocationReferences(references, prepared: prepared)
        try model.authorizedLocations.commit(changes)
        XCTAssertEqual(defaults.data(forKey: AuthorizedLocations.defaultsKey), before,
                       "an uncaptured old-root reference must keep its matching grant")
        XCTAssertEqual(model.calibrationLibrary.all().first?.sourcePath, old.path)
        _ = try await model.acquireReadableLocation(moved)
        XCTAssertEqual(model.calibrationLibrary.all().first { $0.id == frame.id }?.sourcePath, moved.path)
        XCTAssertEqual(model.sessionDarkFlatsFolder?.path, moved.path)
    }

    func testMoreSpecificMovedGrantWinsWhenParentAlsoMoves() async throws {
        let (model, backend, _, root) = try fixture()
        let parent = try directory(root, "parent"), child = try directory(parent, "child")
        let movedParent = try directory(root, "parent-new"), movedChild = try directory(root, "child-new")
        await assertAccessNotNil(await model.selectSourceFolder(parent))
        await model.setCalibrationFolder(child, darkFlats: true)
        model.sessionFlatsFolder = parent
        let references = model.captureLocationReferences()
        backend.moves[parent.path] = movedParent
        backend.moves[child.path] = movedChild
        let prepared = try await model.authorizedLocations.prepare([.url(parent), .url(child)])
        let changes = try model.reconcileLocationReferences(references, prepared: prepared)
        try model.authorizedLocations.commit(changes)
        XCTAssertEqual(model.sessionFlatsFolder?.path, movedParent.path)
        XCTAssertEqual(model.sessionDarkFlatsFolder?.path, movedChild.path)
    }

    private func assertSharedMovedSource(rebuildFirst: Bool) async throws {
        let (model, backend, defaults, root) = try fixture()
        let source = try directory(root, "shared-bias")
        let moved = root.appendingPathComponent("moved-bias")
        let input = try directory(root, "input"), output = try directory(root, "output")
        try writeFITS(source.appendingPathComponent("bias.fit"))
        await assertAccessNotNil(await model.selectSourceFolder(source))
        await model.setCalibrationFolder(source, darkFlats: true)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.addMasterFromFolder(source, kind: .bias)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.calibrationBusy, "prerequisite: calibration build completed")
        let frame = try XCTUnwrap(model.libraryEntries.first)
        try FileManager.default.moveItem(at: source, to: moved)
        backend.moves[source.path] = moved
        if rebuildFirst {
            model.rebuildMaster(frame.id)
            for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(model.calibrationBusy)
        } else {
            _ = try await model.acquireOperationAccess(input: input)
        }
        XCTAssertEqual(model.sessionDarkFlatsFolder?.path, moved.path)
        XCTAssertEqual(model.libraryEntries.first?.sourcePath, moved.path)
        XCTAssertEqual(defaults.string(forKey: "StorePreview.darkFlatsPath"), moved.path)
        if rebuildFirst {
            _ = try await model.acquireOperationAccess(input: input)
        } else {
            model.rebuildMaster(frame.id)
            for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertNil(model.errorMessage)
        let reopened = AppModel(userDefaults: defaults,
                                calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("container/library")),
                                configuration: config(root), bookmarkBackend: backend)
        for _ in 0..<500 where reopened.isRestoringLocationAccess { try await Task.sleep(nanoseconds: 1_000_000) }
        reopened.refreshLibraryEntries()
        XCTAssertEqual(reopened.sessionDarkFlatsFolder?.path, moved.path)
        XCTAssertEqual(reopened.libraryEntries.first?.sourcePath, moved.path)
        _ = try await reopened.acquireOperationAccess(input: input)
    }

    func testCalibrationBuildAndMovedRebuildUseOwnedSourceAndPrivateLibrary() async throws {
        let (model, backend, _, root) = try fixture()
        let source = try directory(root, "darks"), moved = root.appendingPathComponent("moved-darks")
        try writeFITS(source.appendingPathComponent("dark.fit"))
        await assertAccessNotNil(await model.selectSourceFolder(source))
        model.addMasterFromFolder(source, kind: .dark)
        XCTAssertTrue(model.calibrationBusy)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.calibrationBusy)
        let frame = try XCTUnwrap(model.libraryEntries.first)
        XCTAssertEqual(frame.frameCount, 1)
        XCTAssertEqual(backend.balance(source), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("container/library/" + frame.fileName).path))
        try FileManager.default.moveItem(at: source, to: moved)
        try writeFITS(moved.appendingPathComponent("dark2.fit"))
        backend.moved = moved
        model.rebuildMaster(frame.id)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.calibrationBusy)
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.libraryEntries.first?.frameCount, 2)
        XCTAssertEqual(backend.balance(moved), 0)
        model.rebuildMaster(frame.id)
        XCTAssertTrue(model.calibrationBusy, "a second rebuild must use the renewed bookmark's moved source")
        for _ in 0..<500 where model.calibrationBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.errorMessage)
    }

    func testMovedCalibrationSelectionPersistsAcrossTwoFreshAppModels() async throws {
        let (model, backend, defaults, root) = try fixture()
        let original = try directory(root, "flats"), moved = try directory(root, "moved-flats")
        await model.setCalibrationFolder(original, darkFlats: false)
        backend.moved = moved
        let reopened = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        try await waitForAccess { !reopened.isRestoringLocationAccess }
        XCTAssertEqual(reopened.sessionFlatsFolder?.path, moved.path)
        XCTAssertNil(reopened.errorMessage)
        let again = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        try await waitForAccess { !again.isRestoringLocationAccess }
        XCTAssertEqual(again.sessionFlatsFolder?.path, moved.path)
        XCTAssertNil(again.errorMessage)
    }

    func testOperationRenewalPersistsMovedFlatsForNextOperationAndRelaunch() async throws {
        let (model, backend, defaults, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        let old = try directory(root, "flats"), moved = root.appendingPathComponent("moved-flats")
        await model.setCalibrationFolder(old, darkFlats: false)
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        try FileManager.default.moveItem(at: old, to: moved)
        backend.moves[old.path] = moved
        await assertAccessEqual(try await model.acquireOperationAccess(input: input).flats?.path, moved.path)
        XCTAssertEqual(model.sessionFlatsFolder?.path, moved.path)
        await assertAccessEqual(try await model.acquireOperationAccess(input: input).flats?.path, moved.path)
        let reopened = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        await assertAccessEqual(try await reopened.acquireOperationAccess(input: input).flats?.path, moved.path)
        XCTAssertNil(reopened.errorMessage)
    }

    func testMovedInputRemainsUsableAfterLaterCalibrationAcquisitionFails() async throws {
        let (model, backend, defaults, root) = try fixture()
        let old = try directory(root, "input"), moved = root.appendingPathComponent("moved-input")
        let output = try directory(root, "output")
        await assertAccessTrue(await model.selectLocation(old, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.calibration.darkPath = root.appendingPathComponent("not-authorized.fit").path
        model.saveSettings()
        try FileManager.default.moveItem(at: old, to: moved)
        backend.moves[old.path] = moved
        await assertAccessThrows(try await model.acquireOperationAccess(input: old))
        XCTAssertEqual(model.watchFolder?.path, moved.path)
        model.calibration.darkPath = nil
        let selected = try XCTUnwrap(model.watchFolder)
        await assertAccessEqual(try await model.acquireOperationAccess(input: selected).input.path, moved.path)
        let reopened = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        await assertAccessEqual(try await reopened.acquireOperationAccess(input: XCTUnwrap(reopened.watchFolder)).input.path, moved.path)
    }

    func testOperationRenewalPersistsMovedLegacyMasterForNextOperationAndRelaunch() async throws {
        let (model, backend, defaults, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        let old = try directory(root, "masters"), moved = root.appendingPathComponent("moved-masters")
        try writeFITS(old.appendingPathComponent("dark.fit"))
        await assertAccessNotNil(await model.selectSourceFolder(old))
        model.calibration.darkPath = old.appendingPathComponent("dark.fit").path
        model.saveSettings()
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        try FileManager.default.moveItem(at: old, to: moved)
        backend.moves[old.path] = moved
        let expected = moved.appendingPathComponent("dark.fit").path
        await assertAccessEqual(try await model.acquireOperationAccess(input: input).darkPath, expected)
        XCTAssertEqual(model.calibration.darkPath, expected)
        await assertAccessEqual(try await model.acquireOperationAccess(input: input).darkPath, expected)
        let reopened = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        await assertAccessEqual(try await reopened.acquireOperationAccess(input: input).darkPath, expected)
        XCTAssertEqual(CalibrationStore.load(defaults).darkPath, expected)
        XCTAssertNil(reopened.errorMessage)
    }

    func testImportCapturesOutputBeforeMetadataAndReleasesAfterTerminalWork() async throws {
        let (_, backend, defaults, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output"), future = try directory(root, "future")
        let gate = GatedAvailability(target: input)
        defer { gate.release.signal() }
        let model = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend, locationAvailability: gate)
        // A readable but featureless frame is rejected by the real stacker. It still
        // traverses metadata, import, finalization and permission release.
        try writeFITS(input.appendingPathComponent("Light_test.fit"))
        model.calibration.darkPath = input.appendingPathComponent("Light_test.fit").path
        await assertAccessNotNil(await model.selectSourceFolder(input))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.importer.importSubs(from: input)
        XCTAssertTrue(model.importer.isImporting)
        try await waitForAccess { gate.hasEntered }
        XCTAssertEqual(backend.balance(input), 2, "input and selected dark each own their shared parent grant")
        await assertAccessTrue(await model.selectLocation(future, key: "output"))
        gate.release.signal()
        for _ in 0..<1000 where model.importer.isImporting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.importer.isImporting)
        XCTAssertEqual(backend.balance(input), 0)
        XCTAssertEqual(backend.balance(output), 0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: future.path).isEmpty)
        XCTAssertEqual(CalibrationStore.load(defaults).darkPath, model.calibration.darkPath)
    }

    func testPreviewUsesConfiguredCatalogAtInitialization() async throws {
        let (initial, backend, defaults, root) = try fixture()
        XCTAssertEqual(initial.catalogState, .notInstalled, "A new preview must not inspect the direct edition's catalog")
        let catalog = try directory(root, "container/catalog")
        var bytes = Array("LASC".utf8) + [UInt8](repeating: 0, count: 8)
        bytes[8] = 1
        try Data(bytes).write(to: catalog.appendingPathComponent("brightstars.bin"))
        let model = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        XCTAssertEqual(model.catalogState, .installed)
    }

    private func writeFITS(_ url: URL) throws {
        try FITSWriter.float32(width: 8, height: 8, channels: 1, pixels: Array(repeating: 0.1, count: 64)).write(to: url)
    }

    func testPreviewStartWithoutOutputRemainsIdle() async throws {
        let (model, _, _, root) = try fixture()
        model.watchFolder = root
        model.sourceMode = .nativeStack
        var results: [Bool] = []
        model.startSession { results.append($0) }
        try await waitForAccess { !model.isPreparingSessionInput }
        XCTAssertEqual(results, [false])
        XCTAssertFalse(model.isPreparingSessionInput)
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.errorMessage)
        model.cancelSessionInputPreparation()
    }

    func testPreviewImportWithoutOutputDoesNotPrepareOrRetireSession() async throws {
        let (model, _, _, root) = try fixture()
        model.importer.importSubs(from: root)
        try await waitForAccess { !model.importer.isImporting }
        XCTAssertFalse(model.importer.isImporting)
        XCTAssertNotNil(model.errorMessage)
        model.importer.cancelImport()
    }

    func testDeniedCaptureFailsBeforeBaseline() async throws {
        let (model, backend, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.watchFolder = input
        model.sourceMode = .nativeStack
        backend.denied = input
        var started: Bool?
        model.startSession { started = $0 }
        try await waitForAccess { started != nil }
        XCTAssertEqual(started, false)
        XCTAssertFalse(model.isPreparingSessionInput)
        XCTAssertNotNil(model.errorMessage)
        model.cancelSessionInputPreparation()
    }

    func testRestoredCaptureUsesResolvedURLAndUnavailableChoiceStaysVisible() async throws {
        let (model, backend, defaults, root) = try fixture()
        let original = try directory(root, "original"), moved = try directory(root, "moved")
        await assertAccessTrue(await model.selectLocation(original, key: "capture"))
        model.watchFolder = original
        model.saveSettings()
        backend.moved = moved
        let reopened = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        try await waitForAccess { !reopened.isRestoringLocationAccess }
        XCTAssertEqual(reopened.watchFolder?.path, moved.path)
        backend.denied = moved
        let denied = AppModel(userDefaults: defaults, configuration: config(root), bookmarkBackend: backend)
        try await waitForAccess { !denied.isRestoringLocationAccess }
        XCTAssertNotNil(denied.watchFolder)
        XCTAssertNotNil(denied.errorMessage)
    }

    func testPendingQuestionOwnsAccessUntilUserCancels() async throws {
        let (model, backend, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        try FITSWriter.float32(width: 8, height: 8, channels: 1, pixels: Array(repeating: 0.1, count: 64))
            .write(to: input.appendingPathComponent("Light_old.fit"))
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        model.watchFolder = input; model.sourceMode = .nativeStack
        var results: [Bool] = []
        model.startSession { results.append($0) }
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.pendingSessionStart)
        XCTAssertEqual(backend.balance(input), 1)
        XCTAssertEqual(backend.balance(output), 1)
        let future = try directory(root, "future")
        await assertAccessTrue(await model.selectLocation(future, key: "output"))
        XCTAssertEqual(backend.balance(output), 1)
        model.resolvePendingSessionStart(.cancel)
        model.resolvePendingSessionStart(.cancel)
        XCTAssertEqual(results, [false])
        XCTAssertEqual(backend.balance(input), 0)
        XCTAssertEqual(backend.balance(output), 0)
    }

    func testUnavailableCalibrationBlocksStartExplicitly() async throws {
        let (model, _, _, root) = try fixture()
        let input = try directory(root, "input"), output = try directory(root, "output")
        let missing = root.appendingPathComponent("disconnected")
        await assertAccessTrue(await model.selectLocation(input, key: "capture"))
        await assertAccessTrue(await model.selectLocation(output, key: "output"))
        await assertAccessTrue(await model.selectLocation(missing, key: "source:" + missing.absoluteString))
        model.watchFolder = input; model.sourceMode = .nativeStack; model.sessionFlatsFolder = missing
        var started: Bool?
        model.startSession { started = $0 }
        for _ in 0..<500 where model.isPreparingSessionInput { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(started, false)
        XCTAssertFalse(model.isPreparingSessionInput)
        XCTAssertNotNil(model.errorMessage)
        model.cancelSessionInputPreparation()
    }

    func testPreviewEntryMethodsRejectUnprovenIntegrations() async throws {
        let (model, _, _, root) = try fixture()
        // Camera-share entry points have their own authorized discovery coverage.
        model.nightVisionOn = true; model.applyNightVision()
        XCTAssertFalse(model.nightVisionOn)
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        model.processorBackend = .graxpert
        model.importer.processMaster(sessionDirectory: root)
        XCTAssertFalse(model.importer.isProcessing)
        XCTAssertTrue(model.errorMessage?.contains("preview") == true)
        let connected = await model.broadcast.connectAndReconcile()
        XCTAssertFalse(connected)
    }

    private func waitForAccess(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard condition() else { XCTFail("permission operation did not reach its required state", file: file, line: line); throw CancellationError() }
    }

    private func config(_ root: URL) -> StorePreviewConfiguration {
        StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview",
                                  containerRoot: root.appendingPathComponent("container"))
    }

    private func fixture(makeNativeProcessor: @escaping @Sendable () -> any Processor = { NativeDenoiseProcessor() }) throws -> (AppModel, PreviewBookmarkBackend, UserDefaults, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorePreviewTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "StorePreviewTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let backend = PreviewBookmarkBackend()
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        return (AppModel(userDefaults: defaults, calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("container/library")), configuration: config(root), bookmarkBackend: backend, makeNativeProcessor: makeNativeProcessor), backend, defaults, root)
    }

    private func directory(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Parks only the processor boundary; neither captures nor releases access owners.
private final class GatedNativeProcessor: Processor, @unchecked Sendable {
    let name = "Gated Native NR"
    let isAvailable = true
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldPark = false
    private var entered = false
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func parkNextCall() { lock.lock(); shouldPark = true; lock.unlock() }
    func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws -> URL {
        lock.lock(); let park = shouldPark; shouldPark = false; entered = park; lock.unlock()
        if park && release.wait(timeout: .now() + 5) != .success { throw CocoaError(.fileReadUnknown) }
        return try NativeDenoiseProcessor().process(masterURL: masterURL, outputURL: outputURL, log: log)
    }
}

private final class PreviewBookmarkBackend: BookmarkAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDenied: URL?
    private var storedMoved: URL?
    private var storedMoves: [String: URL] = [:]
    var denied: URL? {
        get { lock.lock(); defer { lock.unlock() }; return storedDenied }
        set { lock.lock(); defer { lock.unlock() }; storedDenied = newValue }
    }
    var moved: URL? {
        get { lock.lock(); defer { lock.unlock() }; return storedMoved }
        set { lock.lock(); defer { lock.unlock() }; storedMoved = newValue }
    }
    var moves: [String: URL] {
        get { lock.lock(); defer { lock.unlock() }; return storedMoves }
        set { lock.lock(); defer { lock.unlock() }; storedMoves = newValue }
    }
    private var counts: [String: Int] = [:]
    func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmark(_ data: Data) throws -> BookmarkResolution {
        let path = String(decoding: data, as: UTF8.self)
        lock.lock(); defer { lock.unlock() }
        let resolved = storedMoves[path] ?? storedMoved
        return BookmarkResolution(url: resolved ?? URL(fileURLWithPath: path), isStale: resolved != nil)
    }
    func startAccessing(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard storedDenied?.path != url.path else { return false }
        counts[url.path, default: 0] += 1
        return true
    }
    func stopAccessing(_ url: URL) { lock.lock(); defer { lock.unlock() }; counts[url.path, default: 0] -= 1 }
    func balance(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return counts[url.path, default: 0] }
}

/// Synchronizes a real FITS loader; it never fabricates pixels or performs lease cleanup.
private final class GatedRealFrameLoader: FrameLoader, @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    let release = DispatchSemaphore(value: 0)
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
        lock.lock(); let first = !entered; entered = true; lock.unlock()
        if first && release.wait(timeout: .now() + 5) != .success { throw CocoaError(.fileReadUnknown) }
        return try ProductionFrameLoader(calibratorProvider: { nil }, demosaic: .bilinear)
            .loadRegisteredInput(url: url, expectedContentDigest: expectedContentDigest)
    }
}

private final class GatedAvailability: LocationAvailabilityChecking, @unchecked Sendable {
    let target: URL
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    private var main = false
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return main }
    init(target: URL) { self.target = target }
    func check(_ url: URL, forWriting: Bool) throws {
        if url.path == target.path {
            lock.lock(); entered = true; main = Thread.isMainThread; lock.unlock()
            // Bound a broken main-actor implementation so RED reports, never hangs.
            _ = release.wait(timeout: .now() + (Thread.isMainThread ? 0.5 : 5))
        }
        try FileLocationAvailability().check(url, forWriting: forWriting)
    }
}
