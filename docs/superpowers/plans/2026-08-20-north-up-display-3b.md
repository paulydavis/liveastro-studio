# North-Up Display (3b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A "North up" toggle that rotates the broadcast display (and everything `displayCGImage`
produces) to celestial north-up when a plate solve is available.

**Architecture:** A `northUp` flag on `DisplayAdjustments`; a pure `NorthUpRotation` helper (rotate +
auto-zoom); applied once in `SessionPipeline.displayCGImage` so all display outputs inherit it; a toggle
in `ControlView` enabled only when solved. `master.fit` untouched.

**Tech Stack:** Swift 5.10, SPM, macOS 14+, SwiftUI, CoreGraphics, XCTest. Zero new deps.

## Global Constraints

- Branch `feature/north-up-display-3b` (created). NEVER commit to `main`.
- Commit trailer `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`; no `Co-Authored-By`.
- One `swift test`/`build` at a time; build to `--scratch-path /private/tmp/claude-501/-Users-pauldavis/2349d1c1-e213-4a31-a397-bea11f9674d7/scratchpad/las-build`.
- Rotation is DISPLAY-ONLY: never touch the linear `AstroImage`/master used for stats or `master.fit`.
- Toggle default OFF; no-op (return image un-rotated) when `northUp` on but `currentWCS == nil`.
- **The rotation sign/parity/row-order is EMPIRICAL** — Task 5's real-frame render is the source of truth;
  adjust `NorthUpRotation` until north points up, then keep the synthetic test consistent with it.

---

### Task 1: `DisplayAdjustments.northUp`

**Files:** Modify `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift`; Test `Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift` (extend or create).

- [ ] **Step 1:** Failing test — a `DisplayAdjustments` round-trips `northUp` through Codable, `.neutral` has `northUp == false`, and decoding JSON without the key defaults to false (old sessions).
- [ ] **Step 2:** Run, verify fail.
- [ ] **Step 3:** Add `public var northUp: Bool` to the struct + `.neutral` (false) + memberwise init; ensure Codable decodes missing key as false (`decodeIfPresent ?? false`).
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5:** Commit `feat(north-up): add DisplayAdjustments.northUp`.

---

### Task 2: `NorthUpRotation` pure helper (transform + auto-zoom)

**Files:** Create `Sources/LiveAstroCore/PlateSolve/NorthUpRotation.swift`; Test `Tests/LiveAstroCoreTests/NorthUpRotationTests.swift`.

**Interfaces / Produces:**
- `enum NorthUpRotation { static let autoZoomMaxAngle: Double /* radians, ~15° */ ; static func displayRotationRadians(wcs: WCS) -> Double ; static func apply(_ cg: CGImage, wcs: WCS, autoZoom: Bool) -> CGImage }`

- [ ] **Step 1: Failing geometry test.** For a synthetic `WCS` (rotationDegrees ∈ {0, 30, -95}, both parities), a point at celestial-north of center, mapped to frame pixels by the SAME projection the solver uses (gnomonic north-up grid rotated by +rotationDegrees, x-mirror for parity), must end up ABOVE the image center (smaller top-down y) and east must end up to the LEFT after rotating by `displayRotationRadians`. Assert with a helper that rotates a test point and checks its quadrant.
- [ ] **Step 2:** Run, verify fail (function undefined).
- [ ] **Step 3: Implement.** `displayRotationRadians`: derive from `wcs.rotationDegrees` (+ parity) the angle that rotates the top-down display so north is up / east is left. Start from the self-consistent grid convention; the exact sign is finalized in Task 5. `apply`: build a CoreGraphics context rotated by the angle, draw the CGImage; if `autoZoom && |angle| <= autoZoomMaxAngle`, crop to the largest inscribed axis-aligned rect (removes black corners); else return the full rotated bounding box. Handle parity as a horizontal flip in the draw transform.
- [ ] **Step 4:** Run geometry test, verify pass.
- [ ] **Step 5: Auto-zoom test.** Small angle (~5°) → output has no fully-black corner pixels (inscribed crop); large angle (~95°) → output dimensions equal the rotated bounding box of the input. Assert dims + sample corner pixels.
- [ ] **Step 6:** Run, verify pass. **Commit** `feat(north-up): NorthUpRotation transform + auto-zoom`.

---

### Task 3: Apply rotation in the display path

**Files:** Modify `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (`displayCGImage`, ~:481-510); Test `Tests/LiveAstroCoreTests/SessionPipelineNorthUpTests.swift`.

- [ ] **Step 1: Failing test.** A pipeline with `displayAdjustments.northUp = true` + a solved `currentWCS` (inject via `plateSolveCatalog`, as in 3a's tests) produces a display CGImage rotated vs the same session with `northUp = false`; with `northUp = true` but no catalog (`currentWCS == nil`), the image is identical to `northUp = false` (no-op). (Assert via output dimensions/orientation differing / matching.)
- [ ] **Step 2:** Run, verify fail.
- [ ] **Step 3: Implement.** In `displayCGImage`, after `makeCGImage(display)`: `if adj.northUp, let wcs = currentWCS { return NorthUpRotation.apply(cg, wcs: wcs, autoZoom: true) }`; else return `cg`. (`currentWCS` read is already thread-safe.)
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5: Inherit test.** With `northUp` on + solved, `latest.png` and a snapshot have the same (rotated) dimensions/orientation — proves all display outputs inherit it. **Commit** `feat(north-up): rotate display when toggled + solved`.

---

### Task 4: App toggle + solve availability

**Files:** Modify `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (add `hasSolvedWCS`); `Sources/LiveAstroStudio/AppModel.swift` (`northUp`, `solveAvailable`, wire into `applyDisplayAdjustments`); `Sources/LiveAstroStudio/AppSurface.swift` (expose solve availability if needed); `Sources/LiveAstroStudio/ControlView.swift` (toggle). Tests: `AppModel` behavior where testable.

- [ ] **Step 1:** Add `public var hasSolvedWCS: Bool { currentWCS != nil }` to `SessionPipeline`.
- [ ] **Step 2:** `AppModel`: `var northUp = false` (drives `displayAdjustments.northUp` in `applyDisplayAdjustments()`); `var solveAvailable = false` refreshed on the display-update tick from `pipeline.hasSolvedWCS`.
- [ ] **Step 3:** `ControlView`: in the Display Adjustments section add `helpToggle("North up", isOn: $model.northUp, help: "Rotate the view so celestial north is up. Needs a plate solve (star catalog required).")` with `.disabled(!model.solveAvailable)`.
- [ ] **Step 4:** Build the app target; add/adjust any `AppModel` unit test that can run headless (toggle flips `displayAdjustments.northUp`; `solveAvailable` mirrors `hasSolvedWCS`). **Commit** `feat(north-up): North up toggle in ControlView + solve gating`.

---

### Task 5: Empirical real-frame orientation validation (source of truth)

**Files:** Test `Tests/LiveAstroCoreTests/SessionPipelineNorthUpTests.swift` (gated); possibly adjust `NorthUpRotation.displayRotationRadians` sign.

- [ ] **Step 1: Gated real-frame test** (`LAS_SOLVE_FRAME` + real catalog + `~/Desktop/M63-import`): solve the M63 reference (as in 3a), then verify that projecting a catalog star due-NORTH of the solved center through the full display pipeline (stretch → `NorthUpRotation.apply`) lands ABOVE the image center, and a due-EAST star lands to the LEFT. XCTSkip when env/catalog absent.
- [ ] **Step 2:** Run gated (`LAS_SOLVE_FRAME=1`, real catalog staged). If north is NOT up, flip the sign/parity in `displayRotationRadians`, re-run Task 2's synthetic test (keep it consistent), and re-run this until north is up.
- [ ] **Step 3:** Render the M63 master north-up to a PNG in the scratchpad and visually inspect (Read the image) to confirm it looks correct (belt-and-suspenders on the numeric check).
- [ ] **Step 4: Commit** `test(north-up): empirical M63 north-up orientation validation`.

---

## Post-plan verification
- [ ] Full `swift test` green (build to scratch path).
- [ ] Toggle off → byte-identical display to pre-3b (no behavior change when off).
- [ ] Adversarial cold review of `NorthUpRotation` geometry (parity/sign/crop-rect edge cases) before merge.
