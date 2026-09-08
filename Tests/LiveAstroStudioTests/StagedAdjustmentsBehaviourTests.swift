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

        model.previewRenderOverrideForTest = { _, _, adjustments, _ in
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

        model.previewRenderOverrideForTest = { _, _, _, _ in
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

    /// CGImage is not Sendable; the render override is. The box carries one across, which is safe
    /// here because the image is created once and only read.
    private struct ImageBox: @unchecked Sendable { let cg: CGImage }

    private actor QualityLog {
        private(set) var entries: [(blackPoint: Double, quality: SessionPipeline.PreviewQuality)] = []
        func add(_ bp: Double, _ q: SessionPipeline.PreviewQuality) { entries.append((bp, q)) }
        var all: [(blackPoint: Double, quality: SessionPipeline.PreviewQuality)] { entries }
    }

    /// A draft render must never be the operator's final image. A drag is throttled and its last
    /// tick settles, but a SINGLE unforced edit — one arrow-key nudge, one click on the slider
    /// track — took the un-throttled path straight to `.draft` and stopped there, leaving the
    /// operator judging a half-resolution image with no further event coming to fix it.
    @MainActor func testAnIsolatedDraftEditIsFollowedByASettledRender() async throws {
        let (model, _) = makeAttachedModel()
        let box = ImageBox(cg: try Self.solidImage(0.5))
        let log = QualityLog()
        let settled = expectation(description: "a settled render follows the isolated draft edit")
        settled.assertForOverFulfill = false
        model.previewRenderOverrideForTest = { _, _, adj, quality in
            await log.add(adj.blackPoint, quality)
            if quality == .settled { settled.fulfill() }
            return box.cg
        }

        var adj = model.staged.committed
        adj.blackPoint = 0.3
        model.staged.pending = adj
        model.refreshPreview()          // ONE unforced edit, then no further input at all

        await fulfillment(of: [settled], timeout: 5)
        let all = await log.all
        XCTAssertEqual(all.first?.quality, .draft, "the immediate render should still be cheap")
        XCTAssertTrue(all.contains { $0.quality == .settled },
                      "a settled render must follow with no further input")
    }

    /// The reference pane has its own cache key, and it must include the quality. Without it, the
    /// pane rendered during a drag satisfies the cache permanently: the settled pass that follows
    /// sees "nothing it depends on changed" and skips it, so the reference pane stays at draft
    /// resolution beside a settled "Your edit" — the two panes the operator is comparing are then
    /// not rendered alike, which is the one thing a comparison view must guarantee.
    /// Delivers a broadcast update the way the pipeline does, so tests can exercise the pane
    /// that now shows it. The revision must be the pipeline's current one or `isCurrentDisplay`
    /// rejects it — which is the guard that keeps a stale render off the screen.
    @MainActor private func deliverBroadcast(_ image: CGImage,
                                             to pipeline: SessionPipeline) async {
        // `DisplayPresentation.accept` takes only STRICTLY INCREASING revisions, and
        // `isCurrentDisplay` takes only the pipeline's CURRENT one — so a synthetic delivery has
        // to claim a fresh revision first. Sending immediately afterwards wins the race against
        // the pipeline's own render for that revision, which is then correctly refused as not
        // newer. Both guards are exercised rather than bypassed.
        pipeline.refreshDisplay()
        pipeline.onDisplayUpdate?(DisplayDelivery(
            revision: pipeline.currentDisplayRevision, previewImage: nil, broadcastImage: image,
            cleanMasterSubCount: nil, integrationSeconds: 0, previewIntegrationSeconds: 0,
            subExposureSeconds: 1, record: nil))
        try? await Task.sleep(nanoseconds: 250_000_000)   // the handler hops to the main actor
    }

    /// The reference pane IS the delivered broadcast image, not a re-render of the same source
    /// through the preview path. That is what lets it be labelled "Currently live" truthfully:
    /// the preview path derives its stretch from a downsample and renders a measurably different
    /// curve (PreviewDownsampleHonestyTests), so a re-render could not carry that label.
    @MainActor func testTheReferencePaneShowsTheDeliveredBroadcastImage() async throws {
        let (model, pipeline) = makeAttachedModel()
        let live = try Self.solidImage(0.2)
        // The preview path returns something clearly different, so an accidental re-render would
        // be visible rather than coincidentally equal.
        let box = ImageBox(cg: try Self.solidImage(0.8))
        model.previewRenderOverrideForTest = { _, _, _, _ in box.cg }

        await deliverBroadcast(live, to: pipeline)

        XCTAssertEqual(model.previewCompareImage.flatMap { Self.dataOf($0) }, Self.dataOf(live),
                       "the reference pane must be the delivered broadcast image itself")
        XCTAssertFalse(model.compareHistogram.isEmpty,
                       "its histogram must follow the same image")
    }

    // MARK: - The live pane must admit when it is behind

    /// Apply commits instantly; the committed surfaces re-render asynchronously. Until a delivery
    /// carrying that render arrives, the pane labelled "Currently live" is showing the PREVIOUS
    /// look. Observed on a real 26 MP session with DBE on: the gap ran tens of seconds while Apply
    /// greyed its own button out, so the feature looked broken. The pane must say it is updating.
    @MainActor func testApplyMarksTheLivePaneUpdatingUntilADeliveryArrives() async throws {
        let (model, pipeline) = makeAttachedModel()
        XCTAssertFalse(model.livePaneIsUpdating, "precondition: nothing pending before Apply")

        var pending = model.staged.committed
        pending.blackPoint = 0.25
        model.staged.pending = pending
        model.applyAdjustments()

        XCTAssertTrue(model.livePaneIsUpdating,
                      "after Apply the live pane is behind the committed adjustments and must "
                      + "say so — it is still showing the pre-Apply render")

        // A delivery carrying that revision (or later) is what makes it true again.
        await deliverBroadcast(try Self.solidImage(0.3), to: pipeline)
        XCTAssertFalse(model.livePaneIsUpdating,
                       "a delivery at or past Apply's revision means the live pane caught up")
    }

    /// The clear must be driven by the REVISION, not by "any delivery arrived". A delivery that
    /// predates Apply carries an older render — treating it as the catch-up would clear the badge
    /// while the pane still shows the old look, which is the exact lie this fixes.
    @MainActor func testAnOlderDeliveryDoesNotClearTheUpdatingState() async throws {
        let (model, pipeline) = makeAttachedModel()
        var pending = model.staged.committed
        pending.blackPoint = 0.25
        model.staged.pending = pending
        model.applyAdjustments()
        let pendingRevision = try XCTUnwrap(model.pendingLiveRevision)
        XCTAssertTrue(model.livePaneIsUpdating)

        // Hand-built delivery BELOW Apply's revision, delivered through the real handler.
        pipeline.onDisplayUpdate?(DisplayDelivery(
            revision: pendingRevision - 1, previewImage: nil,
            broadcastImage: try Self.solidImage(0.9), cleanMasterSubCount: nil,
            integrationSeconds: 0, previewIntegrationSeconds: 0, subExposureSeconds: 1, record: nil))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(model.livePaneIsUpdating,
                      "a delivery older than Apply's revision is not the catch-up render")
    }

    /// A pending Apply must not leak across sessions — the import-to-import case.
    ///
    /// Imports bind a new presentation through `wireCallbacks` WITHOUT going through
    /// `setPipeline`/`clearPreview`, so a pending revision used to survive the transition. That is
    /// reachable with no race at all: Apply during an import that accepts no frames leaves the
    /// revision set (image-less deliveries deliberately do not clear it), the import releases its
    /// pipeline, and the next short import restarts revisions from zero — below the stale value —
    /// so nothing it ever delivers can clear the badge. "Updating…" would then stick forever while
    /// the broadcast is in fact showing the committed settings.
    @MainActor func testAPendingApplyDoesNotLeakIntoTheNextSession() async throws {
        let (model, firstPipeline) = makeAttachedModel()

        var pending = model.staged.committed
        pending.blackPoint = 0.25
        model.staged.pending = pending
        model.applyAdjustments()
        let stale = try XCTUnwrap(model.pendingLiveRevision,
                                  "precondition: Apply left a pending revision")
        XCTAssertTrue(model.livePaneIsUpdating)
        _ = firstPipeline

        // A SECOND session binds its presentation the way an import does — wireCallbacks only.
        let second = makePipeline()
        model.wireCallbacks(to: second)

        XCTAssertFalse(model.livePaneIsUpdating,
                       "binding a new presentation must retire the previous session's pending "
                       + "revision — the new pipeline counts from zero and could never clear it")

        // And a delivery from the NEW session at a revision BELOW the stale one is normal here;
        // it must simply be irrelevant rather than leaving the badge stuck.
        XCTAssertLessThan(second.currentDisplayRevision, stale,
                          "precondition: the new pipeline's revisions really do start below the "
                          + "stale value, which is what made this leak permanent")
        await deliverBroadcast(try Self.solidImage(0.4), to: second)
        XCTAssertFalse(model.livePaneIsUpdating)
    }

    /// A continuous drag must not pay for settled renders. The settle was a fixed one-shot timer
    /// armed 90 ms after the FIRST draft and never postponed, so it fired mid-drag and re-armed —
    /// a long drag rendered at full resolution roughly every 90 ms, which is precisely the cost
    /// the draft tier exists to avoid.
    @MainActor func testAContinuousDragDoesNotSettleUntilItStops() async throws {
        let (model, _) = makeAttachedModel()
        let box = ImageBox(cg: try Self.solidImage(0.5))
        let log = QualityLog()
        model.previewRenderOverrideForTest = { _, _, adjustments, quality in
            await log.add(adjustments.blackPoint, quality)
            return box.cg
        }

        // ~300 ms of continuous dragging: long enough that a fixed 90 ms timer fires three times.
        for i in 0..<15 {
            var adj = model.staged.committed
            adj.blackPoint = Double(i) / 100
            model.staged.pending = adj
            model.refreshPreview()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let duringDrag = await log.all
        let settledDuringDrag = duringDrag.filter { $0.quality == .settled }.count
        XCTAssertEqual(settledDuringDrag, 0,
                       "settled renders fired during the drag (\(settledDuringDrag) of "
                       + "\(duringDrag.count) renders); the settle must be reset by each edit")

        // Now stop. The last edit must still settle, or the operator is left on a draft image.
        let settled = expectation(description: "the drag settles once it stops")
        settled.assertForOverFulfill = false
        model.previewRenderOverrideForTest = { _, _, adjustments, quality in
            await log.add(adjustments.blackPoint, quality)
            if quality == .settled { settled.fulfill() }
            return box.cg
        }
        await fulfillment(of: [settled], timeout: 5)
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

        model.previewRenderOverrideForTest = { _, _, adj, _ in
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
        model.previewRenderOverrideForTest = { _, _, adj, _ in
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
    @MainActor func testLivePaneShowsTheBroadcastWhileTheEditPaneFollowsTheDials() async throws {
        let (model, pipeline) = makeAttachedModel()
        let liveImage = try Self.solidImage(0.2)
        let editedBox = ImageBox(cg: try Self.solidImage(0.8))
        model.previewRenderOverrideForTest = { _, _, _, _ in editedBox.cg }

        func renderAndWait() async {
            let done = expectation(description: "render resolved")
            done.assertForOverFulfill = false
            model.previewRenderCompletionForTest = { _, _ in done.fulfill() }
            model.refreshPreview(force: true)
            await fulfillment(of: [done], timeout: 3)
        }

        await deliverBroadcast(liveImage, to: pipeline)
        await renderAndWait()

        // Both panes are a permanent part of the layout, not a comparison that appears once you
        // touch something — gating the live pane on hasPendingChanges meant it never appeared.
        XCTAssertNotNil(model.previewImage, "the editable pane must render")
        XCTAssertNotNil(model.previewCompareImage, "the 'currently live' pane must always show")

        var pending = model.staged.committed
        pending.midtoneStrength = 0.42
        model.staged.pending = pending
        await renderAndWait()

        XCTAssertEqual(model.previewCompareImage.flatMap { Self.dataOf($0) }, Self.dataOf(liveImage),
                       "the live pane must keep showing the BROADCAST — it must not follow the "
                       + "dials, or there is nothing to compare an edit against")
        XCTAssertNotEqual(model.previewImage.flatMap { Self.dataOf($0) },
                          model.previewCompareImage.flatMap { Self.dataOf($0) },
                          "the edit pane follows the dials, so the panes must differ")
    }

    @MainActor func testApplyRerendersBothPanesSoTheyAgreeAfterwards() async throws {
        let (model, attachedPipeline) = makeAttachedModel()

        let baseline = model.staged.committed
        let editedImage = try Self.solidImage(0.8)
        let liveImage = try Self.solidImage(0.2)
        // Renders whatever adjustments it is handed: the baseline look, or the edited look.
        model.previewRenderOverrideForTest = { _, _, adj, _ in
            adj == baseline ? liveImage : editedImage
        }

        func renderAndWait() async {
            let done = expectation(description: "render resolved")
            done.assertForOverFulfill = false
            model.previewRenderCompletionForTest = { _, _ in done.fulfill() }
            model.refreshPreview(force: true)
            await fulfillment(of: [done], timeout: 3)
        }

        var pending = baseline
        pending.midtoneStrength = 0.42
        model.staged.pending = pending
        await renderAndWait()

        // Apply, then wait for the re-render Apply itself must trigger.
        let applied = expectation(description: "apply re-rendered")
        applied.assertForOverFulfill = false
        model.previewRenderCompletionForTest = { _, _ in applied.fulfill() }
        model.applyAdjustments()
        await fulfillment(of: [applied], timeout: 3)

        XCTAssertFalse(model.staged.hasPendingChanges, "Apply commits the edit")
        // The live pane is fed by the pipeline's DELIVERY now, not by a second preview render, so
        // "both panes agree" is no longer something Apply can do on its own — the pipeline
        // re-renders and delivers, and the pane follows that. What Apply must still do is commit
        // and re-render the edit pane; the delivery below stands in for the pipeline's own.
        let appliedPixels = try XCTUnwrap(model.previewImage.flatMap { Self.dataOf($0) })
        await deliverBroadcast(try XCTUnwrap(model.previewImage), to: attachedPipeline)
        XCTAssertEqual(model.previewCompareImage.flatMap { Self.dataOf($0) }, appliedPixels,
                       "once the pipeline delivers the applied look, the live pane shows it")
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
