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

    // MARK: - 3. The comparison never reaches the broadcast

    /// The comparison is now a second IMAGE rather than a mode, so there is no blink state that
    /// could leak into what Apply commits. What still needs pinning is that rendering the
    /// un-rejected counterpart for the operator has no effect on the committed adjustments: the
    /// panel may show two pictures, but Apply publishes exactly the pending values, once.
    @MainActor func testApplyCommitsPendingAdjustmentsWhateverThePanelIsShowing() throws {
        let (plain, plainPipeline) = makeAttachedModel()
        var pending = plain.staged.committed
        pending.midtoneStrength = 0.42
        plain.staged.pending = pending
        plain.applyAdjustments()
        let committedWithoutComparison = plainPipeline.displayAdjustments

        let (comparing, comparingPipeline) = makeAttachedModel()
        comparingPipeline.configureLiveRejection(enabled: true)
        comparingPipeline.publishedMaster = PublishedMaster(
            image: AstroImage(width: 4, height: 4, channels: 1,
                              pixels: [Float](repeating: 0.2, count: 16), sourceIsLinear: false),
            coverage: [Float](repeating: 1, count: 16), survivorCount: 6,
            key: comparingPipeline.currentFreshnessKey())
        XCTAssertTrue(comparing.canCompare, "sanity: a clean master is being served, so the panel compares")
        comparing.staged.pending = pending
        comparing.applyAdjustments()

        XCTAssertEqual(comparingPipeline.displayAdjustments, pending,
                       "Apply commits the pending values")
        XCTAssertEqual(comparingPipeline.displayAdjustments, committedWithoutComparison,
                       "and commits exactly the same thing whether or not the panel is comparing")
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
    /// The cap, and the thing a cap can plausibly break. Draft renders are bounded to
    /// `maxDraftRendersInFlight`; anything beyond that would be wasted work, since the sequence
    /// guard discards every result but the newest on completion anyway — but on a real 26 MP
    /// session a proxy-cache miss makes each of those a full-resolution crop + downsample, so the
    /// waste is measured in hundreds of MB, not cycles. Before the cap this measured 6 of 6
    /// concurrent.
    ///
    /// The second assertion is the one that matters: a bound must not SWALLOW the operator's last
    /// edit. Refuses-to-dispatch must schedule a coalesced retry, or the preview ends up showing
    /// an older value than `staged.pending` — which is what Apply would publish, i.e. the exact
    /// preview-disagrees-with-broadcast failure this feature exists to prevent.
    @MainActor func testDraftRendersAreBoundedAndTheNewestEditStillRenders() async throws {
        let (model, _) = makeAttachedModel()

        actor Tracker {
            private(set) var concurrent = 0
            private(set) var maxConcurrent = 0
            private(set) var seen: [Double] = []
            func enter(_ bp: Double) { concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent); seen.append(bp) }
            func exit() { concurrent -= 1 }
        }
        let tracker = Tracker()
        let gate = RenderGate()
        let n = 6

        model.previewRenderOverrideForTest = { _, _, adj in
            await tracker.enter(adj.blackPoint)
            await gate.waitForRelease()
            await tracker.exit()
            return nil
        }

        for i in 0..<n {
            var adj = model.staged.committed
            adj.blackPoint = Double(i) / 100      // newest edit is 0.05
            model.staged.pending = adj
            model.refreshPreview(force: true)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let observedMax = await tracker.maxConcurrent
        XCTAssertLessThanOrEqual(observedMax, 2,
            "draft renders must be bounded — before the cap this was 6 of 6, each a potential "
            + "full-resolution crop + downsample on a proxy-cache miss")

        // Release the held renders; the coalesced retry must then render the NEWEST pending value.
        await gate.release()
        let rendered = expectation(description: "the newest edit eventually renders")
        rendered.assertForOverFulfill = false
        model.previewRenderOverrideForTest = { _, _, adj in
            if abs(adj.blackPoint - 0.05) < 1e-9 { rendered.fulfill() }
            return nil
        }
        await fulfillment(of: [rendered], timeout: 5)

        let seen = await tracker.seen
        XCTAssertFalse(seen.isEmpty, "at least one render must have been dispatched")
    }

    /// The side-by-side compares the operator's PENDING edit against what is currently live, so:
    /// with no edit there is one pane, and with an edit there are two that must differ. The
    /// reference pane renders the SAME source with the COMMITTED adjustments — which is what
    /// makes it hold still while the dials move the other one. (It previously showed the
    /// un-rejected master, which compared rejection rather than the edit, and looked identical
    /// because the two masters differ over 0.13% of the frame.)
    @MainActor func testSideBySideComparesThePendingEditAgainstWhatIsLive() async throws {
        let (model, _) = makeAttachedModel()

        // The override distinguishes the two renders by the ADJUSTMENTS handed to them, which is
        // exactly what production varies between the panes.
        let committedBaseline = model.staged.committed
        let editedImage = try Self.solidImage(0.8)
        let liveImage = try Self.solidImage(0.2)
        model.previewRenderOverrideForTest = { _, _, adj in
            adj == committedBaseline ? liveImage : editedImage
        }

        func renderAndWait() async {
            let done = expectation(description: "render resolved")
            done.assertForOverFulfill = false
            model.previewRenderCompletionForTest = { _, _ in done.fulfill() }
            model.refreshPreview(force: true)
            await fulfillment(of: [done], timeout: 3)
        }

        // Nothing edited: one pane. A second pane here would show the same picture twice.
        await renderAndWait()
        XCTAssertNotNil(model.previewImage, "the primary preview must render")
        XCTAssertNil(model.previewCompareImage,
                     "with no pending edit there is nothing to compare against — the panel must "
                     + "not render a reference identical to the preview")

        // Edit a dial: now both panes, and they must differ.
        var pending = model.staged.committed
        pending.midtoneStrength = 0.42
        model.staged.pending = pending
        await renderAndWait()

        let edited = try XCTUnwrap(model.previewImage.flatMap { Self.dataOf($0) })
        let live = try XCTUnwrap(model.previewCompareImage.flatMap { Self.dataOf($0) },
                                 "a pending edit must render the 'currently live' reference pane")
        XCTAssertNotEqual(edited, live,
                          "the panes must differ — equal pixels would mean the reference is being "
                          + "rendered with the pending adjustments too, so both would follow the dials")
        XCTAssertEqual(live, Self.dataOf(liveImage),
                       "the reference must be rendered with the COMMITTED adjustments")

        // Revert: back to a single pane.
        model.revertAdjustments()
        await renderAndWait()
        XCTAssertNil(model.previewCompareImage, "reverting removes the thing being compared")
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
