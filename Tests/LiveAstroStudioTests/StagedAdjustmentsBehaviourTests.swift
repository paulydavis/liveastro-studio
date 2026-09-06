import XCTest
import CoreGraphics
@testable import LiveAstroCore
@testable import LiveAstroStudio

/// Model-behaviour tests for the staged (draft vs. committed) display-adjustments feature,
/// post-merge with main's `DisplayDelivery`. Deliberately has NO `NSHostingView` rendering —
/// those stay in `BroadcastDeliveryTests`; this file only exercises `AppModel` + `SessionPipeline`
/// through the real production entry points (`applyAdjustments()`, `revertAdjustments()`,
/// `resetAdjustments()`, `refreshPreview(force:)`), never by assigning `previewImage` /
/// `latestImage` / `broadcastImage` directly and never by reimplementing what those methods do.
///
/// `AppModel.pipeline` stays `private`; tests reach it only through the narrow test-only seam
/// `AppModel.attach(pipeline:)`, which itself calls the SAME private `setPipeline(_:)`
/// `startSession()`/`endSession()` call — so a test exercising a session transition runs through
/// the real invalidation, not a parallel re-implementation of it (see `AppModel.swift`). A second
/// seam pair, `previewRenderOverrideForTest`/`previewRenderCompletionForTest`, stands in for
/// `SessionPipeline.renderPreview(source:adjustments:)` and reports the real `previewRenderSeq`
/// guard's outcome, so tests can control render TIMING and await a definite acknowledgement of a
/// specific render's resolution — never by polling `previewImage` or sleeping a guessed duration.
///
/// Every `AppModel` here is constructed with a throwaway `UserDefaults` suite (see
/// `makeIsolatedModel()`), NEVER the no-arg `AppModel()` — `AppModel.init` reads/writes
/// `sessionSettings.v1`/calibration keys through its injected `userDefaults`, and the real user's
/// `com.pauldavis.liveastrostudio` domain holds their actual settings. Running these tests must
/// not move a single byte of it.
final class StagedAdjustmentsBehaviourTests: XCTestCase {

    // MARK: - Shared fixtures

    /// One throwaway `UserDefaults` suite per model, so `loadSettings()` (read path, called from
    /// `init`) and `saveSettings()` (write path, called from `applyAdjustments()`) both go
    /// through an isolated domain — never `.standard`, never the real
    /// `com.pauldavis.liveastrostudio` domain. `removePersistentDomain` runs BEFORE (defensive,
    /// in the vanishingly unlikely case a UUID suite name were ever reused) and is registered via
    /// `addTeardownBlock` to run AFTER the test too, so nothing from this suite outlives it. An
    /// instance method (not `static`) precisely so it can register that teardown on `self`.
    @MainActor
    private func makeIsolatedModel() -> AppModel {
        let suiteName = "StagedAdjustmentsBehaviourTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return AppModel(userDefaults: defaults)
    }

    @MainActor
    private func makePipeline(subExposureSeconds: Double = 20) -> SessionPipeline {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return SessionPipeline(watchFolder: sandbox,
            profile: SessionProfile(targetName: "Staged", subExposureSeconds: subExposureSeconds),
            rootDirectory: sandbox)
    }

    /// A model with a real `SessionPipeline` attached exactly the way `startSession()` attaches
    /// one — `wireCallbacks(to:)` for the display-delivery callbacks, then the pipeline's
    /// `displayAdjustments` primed to the model's committed value (mirroring
    /// `startSession()`'s `p.displayAdjustments = staged.committed`), then `attach(pipeline:)`.
    @MainActor
    private func makeAttachedModel(subExposureSeconds: Double = 20) -> (AppModel, SessionPipeline) {
        let model = makeIsolatedModel()
        let pipeline = makePipeline(subExposureSeconds: subExposureSeconds)
        pipeline.displayAdjustments = model.staged.committed
        model.wireCallbacks(to: pipeline)
        model.attach(pipeline: pipeline)
        return (model, pipeline)
    }

    private static func solidImage(_ value: Float) throws -> CGImage {
        try XCTUnwrap(AutoStretch.makeCGImage(AstroImage(width: 4, height: 4, channels: 1,
            pixels: [Float](repeating: value, count: 16), sourceIsLinear: false)))
    }

    /// Coordinates a draft render that the test wants to hold open past some other event, then
    /// release deliberately — the mechanism `testStaleDraftRenderCannotPublishAfterANewerDraftIsRequested`
    /// and `testSessionSwitchRejectsInFlightDraftWithNoNewerDraftRequested` use to build a REAL
    /// completion race instead of asserting on an internal stamp's value.
    /// `waitForRelease()` supports MULTIPLE concurrent callers (needed by
    /// `testRefreshPreviewHasNoBoundOnConcurrentRendersInFlight`, which blocks N renders open at
    /// once) — every registered continuation is resumed on `release()`, not just the most recent.
    private actor RenderGate {
        private var hasStarted = false
        private var shouldRelease = false
        private var startedContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            hasStarted = true
            startedContinuation?.resume()
            startedContinuation = nil
        }

        func waitUntilStarted() async {
            if hasStarted { return }
            await withCheckedContinuation { startedContinuation = $0 }
        }

        func release() {
            shouldRelease = true
            let waiters = releaseContinuations
            releaseContinuations = []
            for c in waiters { c.resume() }
        }

        func waitForRelease() async {
            if shouldRelease { return }
            await withCheckedContinuation { releaseContinuations.append($0) }
        }
    }

    // MARK: - 1. The staging invariant, behaviourally

    /// Replaces a deleted source-text grep. Proves it by DOING it: with a pending edit
    /// outstanding (and a draft render actually requested), the pipeline's committed adjustments
    /// must not move; only `applyAdjustments()` may move them.
    @MainActor func testPendingEditsDoNotReachThePipelineUntilApply() throws {
        let (model, pipeline) = makeAttachedModel()
        let committed = model.staged.committed
        XCTAssertEqual(pipeline.displayAdjustments, committed)

        var pending = committed
        pending.blackPoint = 0.15
        model.staged.pending = pending
        model.refreshPreview(force: true)   // a real draft render request — must not touch the pipeline

        XCTAssertEqual(pipeline.displayAdjustments, committed,
                       "pending edits (and requesting a draft render of them) must not reach the pipeline")

        model.applyAdjustments()

        XCTAssertEqual(pipeline.displayAdjustments, pending,
                       "Apply must promote the pending value to the pipeline's committed adjustments")
    }

    // MARK: - 2. Revert

    @MainActor func testRevertDiscardsPendingAndNeverTouchesThePipeline() throws {
        let (model, pipeline) = makeAttachedModel()
        let committed = model.staged.committed
        var pending = committed
        pending.saturation = 1.6
        model.staged.pending = pending

        model.revertAdjustments()

        XCTAssertEqual(model.staged.pending, committed, "revert must discard the pending edit")
        XCTAssertFalse(model.staged.hasPendingChanges)
        XCTAssertEqual(pipeline.displayAdjustments, committed,
                       "revert must never reach the pipeline — only Apply may")
    }

    // MARK: - 3. Compare never reaches the broadcast

    /// With `blinkHeld == true` (the panel showing the online master to the operator),
    /// `applyAdjustments()` must still commit the pending ADJUSTMENTS, and the committed result
    /// must be identical to what an otherwise-identical Apply produces with blink OFF — proving
    /// blink state and `previewSource` have zero influence on what Apply commits.
    @MainActor func testApplyCommitsPendingAdjustmentsRegardlessOfBlinkOrPreviewSource() throws {
        let (modelNoBlink, pipelineNoBlink) = makeAttachedModel()
        var pending = modelNoBlink.staged.committed
        pending.midtoneStrength = 0.42
        modelNoBlink.staged.pending = pending
        modelNoBlink.blinkHeld = false
        modelNoBlink.applyAdjustments()
        let committedWithoutBlink = pipelineNoBlink.displayAdjustments

        let (modelBlink, pipelineBlink) = makeAttachedModel()
        modelBlink.staged.pending = pending
        modelBlink.blinkHeld = true
        XCTAssertEqual(modelBlink.previewSource, .online,
                       "sanity: blink held really does select the online master for the DRAFT preview")
        modelBlink.applyAdjustments()
        let committedWithBlink = pipelineBlink.displayAdjustments

        XCTAssertEqual(committedWithBlink, pending,
                       "Apply must commit the pending ADJUSTMENTS")
        XCTAssertEqual(committedWithBlink, committedWithoutBlink,
                       "blink/previewSource must not influence what Apply commits — both runs, " +
                       "identical pending edits, must commit identically regardless of blink state")
    }

    // MARK: - 4. Stale draft completion — the scenario, not the mechanism

    /// Constructs the actual race: an older draft render is started and held open past a newer
    /// one being requested and RESOLVING first; only then is the older one released. Uses
    /// `previewRenderCompletionForTest` to await a definite acknowledgement of each render's
    /// resolution (never a poll loop or a guessed sleep), and asserts on both the reported
    /// outcome AND the final `previewImage` — proving the older result cannot land, not merely
    /// that a stamp exists.
    @MainActor func testStaleDraftRenderCannotPublishAfterANewerDraftIsRequested() async throws {
        let (model, _) = makeAttachedModel()
        let gate = RenderGate()

        var older = model.staged.committed; older.blackPoint = 0.11
        var newer = model.staged.committed; newer.blackPoint = 0.22
        let imageOlder = try Self.solidImage(0.9)
        let imageNewer = try Self.solidImage(0.1)
        let olderBlackPoint = older.blackPoint

        model.previewRenderOverrideForTest = { _, _, adjustments in
            if adjustments.blackPoint == olderBlackPoint {
                await gate.markStarted()
                await gate.waitForRelease()   // held open deliberately
                return imageOlder
            }
            return imageNewer
        }

        // Completions arrive in a known ORDER (older is blocked, so it cannot resolve before
        // newer does) — not identified by seq number, which this test deliberately never reads.
        let firstResolved = expectation(description: "first render resolved (the newer one)")
        let secondResolved = expectation(description: "second render resolved (the stale older one)")
        var firstPublished: Bool?
        var secondPublished: Bool?
        model.previewRenderCompletionForTest = { _, published in
            if firstPublished == nil { firstPublished = published; firstResolved.fulfill() }
            else { secondPublished = published; secondResolved.fulfill() }
        }

        model.staged.pending = older
        model.refreshPreview(force: true)          // starts the OLDER render
        await gate.waitUntilStarted()               // it is genuinely in flight now

        model.staged.pending = newer
        model.refreshPreview(force: true)          // supersedes it — the NEWER request

        await fulfillment(of: [firstResolved], timeout: 3)
        XCTAssertEqual(firstPublished, true, "the newer (unblocked) render must publish")
        XCTAssertEqual(model.previewImage.flatMap { Self.dataOf($0) }, Self.dataOf(imageNewer),
                       "the newer render's image must be showing before the stale one is even released")

        await gate.release()   // NOW let the stale older render proceed to resolution
        await fulfillment(of: [secondResolved], timeout: 3)   // a real acknowledgement, not a sleep

        XCTAssertEqual(secondPublished, false,
                       "the older, now-stale render must be discarded by the seq guard, not published")
        XCTAssertEqual(model.previewImage.flatMap { Self.dataOf($0) }, Self.dataOf(imageNewer),
                       "a slower OLDER draft render resolving AFTER a newer one must not overwrite " +
                       "the preview it already landed")
    }

    // MARK: - 5. Session switch rejects an in-flight draft even with no newer draft

    /// The case #4 does not cover: an old draft completion must be rejected after a session
    /// transition even when nothing newer was ever requested afterward. Goes through
    /// `attach(pipeline:)`, which calls the SAME private `setPipeline(_:)` `startSession()`/
    /// `endSession()` use — so this exercises the real invalidation, not a re-implementation of
    /// it (see the falsification record in the behaviour-tests report: with that shared method's
    /// `clearPreview()` call removed, this test fails; restored, it passes).
    @MainActor func testSessionSwitchRejectsInFlightDraftWithNoNewerDraftRequested() async throws {
        let (model, _) = makeAttachedModel()
        let pipelineNew = makePipeline()
        let gate = RenderGate()
        let staleImage = try Self.solidImage(0.9)

        model.previewRenderOverrideForTest = { _, _, _ in
            await gate.markStarted()
            await gate.waitForRelease()
            return staleImage
        }

        let resolved = expectation(description: "stale render resolved")
        var published: Bool?
        model.previewRenderCompletionForTest = { _, wasPublished in
            published = wasPublished
            resolved.fulfill()
        }

        var pending = model.staged.committed; pending.blackPoint = 0.09
        model.staged.pending = pending
        model.refreshPreview(force: true)
        await gate.waitUntilStarted()   // the draft render is genuinely in flight

        XCTAssertNil(model.previewImage, "nothing has landed yet")

        // Session switch: a new pipeline replaces the old one. Deliberately NOT followed by
        // another refreshPreview() call — this is the "no newer draft" case.
        model.attach(pipeline: pipelineNew)

        await gate.release()   // let the stale draft, from the OLD session, resolve
        await fulfillment(of: [resolved], timeout: 3)   // a real acknowledgement, not a sleep

        XCTAssertEqual(published, false,
                       "an old draft resolving after a session switch must be discarded, not published")
        XCTAssertNil(model.previewImage,
                     "an old draft completing after a session switch must not repopulate the " +
                     "preview, even though nothing newer was ever requested")
    }

    // MARK: - Isolation: AppModel must read AND write through the injected suite only

    /// Direct evidence for BOTH paths, not just an assumption that redirecting the write
    /// somehow implies the read is redirected too. A value is seeded directly into a throwaway
    /// suite (one `.standard`/the real `com.pauldavis.liveastrostudio` domain could never
    /// contain), `AppModel.init`'s `loadSettings()` must surface it — proving the READ path is
    /// wired to the injected instance, not `.standard`. Then `saveSettings()` writes a second
    /// probe value and this test reads the suite back directly (bypassing AppModel) to confirm
    /// the WRITE path too. Finally, `.standard` itself is read directly and asserted to contain
    /// NEITHER probe value, so this isn't merely "the suite has a copy" — `.standard` is
    /// affirmatively confirmed untouched by this test.
    @MainActor func testAppModelReadsAndWritesThroughTheInjectedUserDefaultsSuiteOnly() throws {
        let suiteName = "StagedAdjustmentsBehaviourTests.isolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        var seeded = SessionSettings.defaults
        seeded.targetName = "ISOLATION-READ-PROBE-\(UUID().uuidString)"
        SessionSettingsStore.save(seeded, to: defaults)

        let model = AppModel(userDefaults: defaults)
        XCTAssertEqual(model.targetName, seeded.targetName,
                       "AppModel.init (loadSettings) must read through the INJECTED UserDefaults " +
                       "— this value exists ONLY in the temp suite, never in .standard")

        let writeProbe = "ISOLATION-WRITE-PROBE-\(UUID().uuidString)"
        model.targetName = writeProbe
        model.saveSettings()
        XCTAssertEqual(SessionSettingsStore.load(defaults).targetName, writeProbe,
                       "saveSettings() must write through the injected suite")

        let standardContents = SessionSettingsStore.load(.standard)
        XCTAssertNotEqual(standardContents.targetName, seeded.targetName,
                         "the REAL .standard domain must not contain the read probe")
        XCTAssertNotEqual(standardContents.targetName, writeProbe,
                         "the REAL .standard domain must not contain the write probe — " +
                         "saveSettings() must never reach it")
    }

    // MARK: - 6. No redundant refresh on Apply

    /// `SessionPipeline.displayAdjustments`'s setter already calls `refreshDisplay()`
    /// (SessionPipeline.swift:794 at merge time). This pins the uncommitted one-line fix that
    /// removed a second explicit `refreshDisplay()` call from `applyAdjustments()` — with it,
    /// Apply bumped the display revision TWICE per Apply, invalidating the render the setter had
    /// just scheduled.
    @MainActor func testApplyAdjustmentsBumpsTheDisplayRevisionExactlyOnce() throws {
        let (model, pipeline) = makeAttachedModel()
        var pending = model.staged.committed
        pending.blackPoint = 0.05
        model.staged.pending = pending

        let before = try XCTUnwrap(Self.currentDisplayRevision(pipeline),
                                   "could not read the pipeline's current display revision")
        model.applyAdjustments()
        let after = try XCTUnwrap(Self.currentDisplayRevision(pipeline),
                                  "could not read the pipeline's display revision after Apply")

        XCTAssertEqual(after, before + 1,
                       "applyAdjustments() must bump the display revision exactly once — a second " +
                       "explicit refreshDisplay() call would bump it twice")
    }

    // MARK: - OPEN RISK (documented, not fixed): refreshPreview has no bound on concurrent renders

    /// NOT a correctness fix — a measurement. `previewRenderSeq` rejects a stale RESULT from
    /// publishing, but nothing bounds how many `renderPreview` calls may be OUTSTANDING at once.
    /// Every `force: true` caller (Revert, Reset, blink press/release, a new frame, a session
    /// boundary) bypasses the 80 ms throttle entirely, so N such calls landing while a slow
    /// render is still in flight spawn N concurrent full renders. Demonstrates this directly:
    /// blocks every render open and counts how many are simultaneously executing.
    @MainActor func testRefreshPreviewHasNoBoundOnConcurrentRendersInFlight() async throws {
        let (model, _) = makeAttachedModel()

        actor Counter {
            private(set) var concurrent = 0
            private(set) var maxConcurrent = 0
            func enter() { concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent) }
            func exit() { concurrent -= 1 }
        }
        let counter = Counter()
        let gate = RenderGate()
        let n = 6

        var resolvedCount = 0
        let allResolved = expectation(description: "all \(n) renders resolved")
        model.previewRenderCompletionForTest = { _, _ in
            resolvedCount += 1
            if resolvedCount == n { allResolved.fulfill() }
        }
        model.previewRenderOverrideForTest = { _, _, _ in
            await counter.enter()
            await gate.waitForRelease()   // hold every call open at once — nothing here throttles them
            await counter.exit()
            return nil
        }

        for i in 0..<n {
            var adj = model.staged.committed
            adj.blackPoint = Double(i) / 100
            model.staged.pending = adj
            model.refreshPreview(force: true)   // force bypasses the throttle entirely
        }
        // Give the N detached tasks a moment to actually reach the override and start blocking.
        try await Task.sleep(nanoseconds: 150_000_000)
        let observedMax = await counter.maxConcurrent

        await gate.release()
        await fulfillment(of: [allResolved], timeout: 3)

        print("OPEN-RISK-MEASUREMENT: \(observedMax) of \(n) forced refreshPreview() calls were " +
              "simultaneously in flight — refreshPreview has no bound on outstanding detached renders.")
        XCTAssertEqual(observedMax, n,
                      "documents the open risk: the seq guard rejects stale RESULTS but does not " +
                      "bound how many renders may be executing at once")
    }

    // MARK: - Helpers

    private static func dataOf(_ image: CGImage) -> Data? { image.dataProvider?.data as Data? }

    /// Finds the pipeline's current display revision via the only introspection it exposes,
    /// `isCurrentDisplay`, by probing small revision numbers. Bounded because every path in this
    /// file only ever bumps it a handful of times.
    private static func currentDisplayRevision(_ pipeline: SessionPipeline, upperBound: UInt64 = 20) -> UInt64? {
        for revision in 0...upperBound {
            let probe = DisplayDelivery(revision: revision, previewImage: nil, broadcastImage: nil,
                cleanMasterSubCount: nil, integrationSeconds: 0, previewIntegrationSeconds: 0,
                subExposureSeconds: 1, record: nil)
            if pipeline.isCurrentDisplay(probe) { return revision }
        }
        return nil
    }
}
