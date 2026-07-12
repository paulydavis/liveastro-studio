# Help Markdown Renderer + Content Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the in-app Help with correct block-level markdown (headings, lists, table, blockquote, rules) instead of literal text, and refresh Help.md to cover the current app.

**Architecture:** A pure, Foundation-only block parser (`MarkdownBlocks.parse → [MarkdownBlock]`) lives in `LiveAstroCore` and is unit-tested; `HelpView` (app target) renders `[MarkdownBlock]` as native SwiftUI views, interpreting inline **bold**/*italic*/`code` per block via `AttributedString`'s inline parser. `Help.md` content is rewritten within the parser's supported subset.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftPM, XCTest. Zero external dependencies.

## Global Constraints

- Swift 5.10, macOS 14+.
- `LiveAstroCore` may import Foundation / CoreGraphics / Accelerate only. `MarkdownBlocks` uses **Foundation only**.
- Zero external dependencies (no swift-markdown, no MarkdownUI).
- Core logic is TDD'd and runs via `swift test --filter LiveAstroCoreTests`. SwiftUI/app code is build/manual-verified (no XCTest for the app target, same as prior pillars).
- Parse only the block constructs Help.md uses: ATX headings (`#`..`######`), paragraphs, `-`/`*` bullet lists, `N.` numbered lists, GitHub pipe tables, `>` blockquotes, `---` rules, and inline bold/italic/code. No code fences, no nested lists, no images, no reference links.
- New source group: `Sources/LiveAstroCore/Text/`.
- Co-Authored-By Claude trailer is allowed in this repo.

---

### Task 1: `MarkdownBlock` value type + `MarkdownBlocks.parse` (TDD)

**Files:**
- Create: `Sources/LiveAstroCore/Text/MarkdownBlocks.swift`
- Test: `Tests/LiveAstroCoreTests/MarkdownBlocksTests.swift`

**Interfaces:**
- Consumes: nothing (leaf logic).
- Produces:
  - `public enum MarkdownBlock: Equatable { case heading(level: Int, text: String); case paragraph(String); case bulletList([String]); case numberedList([String]); case table(headers: [String], rows: [[String]]); case quote(String); case rule }`
  - `public enum MarkdownBlocks { public static func parse(_ markdown: String) -> [MarkdownBlock] }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/MarkdownBlocksTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class MarkdownBlocksTests: XCTestCase {

    func testHeadingLevelsAndTrim() {
        XCTAssertEqual(MarkdownBlocks.parse("# Title"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(MarkdownBlocks.parse("###   Spaced  "), [.heading(level: 3, text: "Spaced")])
    }

    func testHeadingLevelClampAndNonHeading() {
        // 7 hashes: not a valid ATX heading (max 6) → paragraph, verbatim text preserved.
        XCTAssertEqual(MarkdownBlocks.parse("####### Deep"), [.paragraph("####### Deep")])
        // '#' with no following space is not a heading.
        XCTAssertEqual(MarkdownBlocks.parse("#NoSpace"), [.paragraph("#NoSpace")])
    }

    func testRule() {
        XCTAssertEqual(MarkdownBlocks.parse("---"), [.rule])
        XCTAssertEqual(MarkdownBlocks.parse("a\n\n---\n\nb"),
                       [.paragraph("a"), .rule, .paragraph("b")])
    }

    func testTable() {
        let md = """
        | Mode | What |
        |------|------|
        | **Seestar Live** | Watches output |
        | Raw subs | Stacks natively |
        """
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .table(headers: ["Mode", "What"],
                   rows: [["**Seestar Live**", "Watches output"],
                          ["Raw subs", "Stacks natively"]])
        ])
    }

    func testTableSeparatorNotEmittedAndCellTrim() {
        let md = "|  A  |  B  |\n| :--- | ---: |\n| 1 | 2 |"
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .table(headers: ["A", "B"], rows: [["1", "2"]])
        ])
    }

    func testPipeLineWithoutSeparatorIsParagraph() {
        // A lone pipe line with no separator row underneath is not a table.
        XCTAssertEqual(MarkdownBlocks.parse("| not a table"),
                       [.paragraph("| not a table")])
    }

    func testBulletListGroupsAndStripsMarker() {
        let md = "- one\n* two\n- three"
        XCTAssertEqual(MarkdownBlocks.parse(md),
                       [.bulletList(["one", "two", "three"])])
    }

    func testNumberedListGroupsAndRenumberAgnostic() {
        // Non-contiguous source numbers still collapse into one list; text keeps no number.
        let md = "1. first\n1. second\n5. third"
        XCTAssertEqual(MarkdownBlocks.parse(md),
                       [.numberedList(["first", "second", "third"])])
    }

    func testBulletThenNumberedAreSeparateBlocks() {
        XCTAssertEqual(MarkdownBlocks.parse("- a\n1. b"),
                       [.bulletList(["a"]), .numberedList(["b"])])
    }

    func testBlockquoteJoinsConsecutive() {
        XCTAssertEqual(MarkdownBlocks.parse("> line one\n> line two"),
                       [.quote("line one line two")])
    }

    func testBlankFlushesAndParagraphSeparation() {
        XCTAssertEqual(MarkdownBlocks.parse("para a\n\npara b"),
                       [.paragraph("para a"), .paragraph("para b")])
    }

    func testConsecutivePlainLinesJoinIntoOneParagraph() {
        XCTAssertEqual(MarkdownBlocks.parse("soft\nbreak"),
                       [.paragraph("soft break")])
    }

    func testParagraphFollowedByListWithoutBlankLine() {
        XCTAssertEqual(MarkdownBlocks.parse("intro:\n- a\n- b"),
                       [.paragraph("intro:"), .bulletList(["a", "b"])])
    }

    func testInlineMarkupLeftVerbatimForRenderer() {
        // Parser must NOT strip/alter inline syntax; the renderer interprets it.
        XCTAssertEqual(MarkdownBlocks.parse("Use **bold** and `code`."),
                       [.paragraph("Use **bold** and `code`.")])
    }

    // End-to-end regression guard (the original bug): the real bundled Help.md
    // must parse such that NO paragraph still begins with an unconsumed block
    // marker (#, |, >, "- ", or "N. ") — that would mean a construct fell
    // through to literal text. Reads the file from the repo via #filePath so it
    // does not depend on the app target's resource bundle.
    func testBundledHelpHasNoFallenThroughBlockMarkers() throws {
        let testFile = URL(fileURLWithPath: #filePath)                  // …/Tests/LiveAstroCoreTests/MarkdownBlocksTests.swift
        let repoRoot = testFile
            .deletingLastPathComponent()                               // …/Tests/LiveAstroCoreTests
            .deletingLastPathComponent()                               // …/Tests
            .deletingLastPathComponent()                               // repo root
        let helpURL = repoRoot
            .appendingPathComponent("Sources/LiveAstroStudio/Resources/Help.md")
        let md = try String(contentsOf: helpURL, encoding: .utf8)
        let blocks = MarkdownBlocks.parse(md)
        for block in blocks {
            if case let .paragraph(text) = block {
                let t = text.trimmingCharacters(in: .whitespaces)
                XCTAssertFalse(startsWithBlockMarker(t),
                               "Paragraph still starts with an unconsumed markdown marker: \(t)")
            }
        }
    }

    private func startsWithBlockMarker(_ t: String) -> Bool {
        if t.hasPrefix("|") || t.hasPrefix(">") { return true }
        if t == "---" { return true }
        // "# " … "###### "
        if let hashEnd = t.firstIndex(where: { $0 != "#" }),
           t.startIndex != hashEnd,
           t.distance(from: t.startIndex, to: hashEnd) <= 6,
           t[hashEnd] == " " { return true }
        // "- " or "* "
        if t.hasPrefix("- ") || t.hasPrefix("* ") { return true }
        // "N. "
        let chars = Array(t); var k = 0
        while k < chars.count && chars[k].isNumber { k += 1 }
        if k > 0, k + 1 < chars.count, chars[k] == ".", chars[k + 1] == " " { return true }
        return false
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MarkdownBlocksTests`
Expected: FAIL — `cannot find 'MarkdownBlocks' in scope` (type not defined yet). (The bundled-Help test will error resolving the file; that's fine — it turns green once the parser exists AND Help.md remains within the subset. Help.md already is, so it passes at this task.)

- [ ] **Step 3: Write the parser**

Create `Sources/LiveAstroCore/Text/MarkdownBlocks.swift`:

```swift
import Foundation

/// A block-level element of a limited markdown subset. Inline markup
/// (**bold**, *italic*, `code`) is preserved verbatim inside each block's
/// text — the renderer is responsible for interpreting it.
public enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case numberedList([String])
    case table(headers: [String], rows: [[String]])
    case quote(String)
    case rule
}

/// Parses the block structure of the markdown subset used by Help.md.
/// Deliberately NOT a full CommonMark parser (YAGNI): it handles ATX
/// headings, paragraphs, `-`/`*` bullet lists, `N.` numbered lists, GitHub
/// pipe tables, `>` blockquotes, and `---` rules. Anything else is treated
/// as paragraph text.
public enum MarkdownBlocks {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []

        var para: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var quotes: [String] = []

        func flushPara()    { if !para.isEmpty    { blocks.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushBullets() { if !bullets.isEmpty { blocks.append(.bulletList(bullets)); bullets = [] } }
        func flushNumbers() { if !numbers.isEmpty { blocks.append(.numberedList(numbers)); numbers = [] } }
        func flushQuotes()  { if !quotes.isEmpty  { blocks.append(.quote(quotes.joined(separator: " "))); quotes = [] } }
        func flushAll()     { flushPara(); flushBullets(); flushNumbers(); flushQuotes() }

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flushAll(); i += 1; continue }

            if line == "---" { flushAll(); blocks.append(.rule); i += 1; continue }

            if let h = headingMatch(line) { flushAll(); blocks.append(.heading(level: h.0, text: h.1)); i += 1; continue }

            // Pipe table: a '|' line immediately followed by a separator row.
            if line.hasPrefix("|"), i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushAll()
                let headers = tableCells(line)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let cand = lines[j].trimmingCharacters(in: .whitespaces)
                    guard cand.hasPrefix("|") else { break }
                    rows.append(tableCells(cand)); j += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                i = j; continue
            }

            if let b = bulletMatch(line) { flushPara(); flushNumbers(); flushQuotes(); bullets.append(b); i += 1; continue }
            if let n = numberMatch(line) { flushPara(); flushBullets(); flushQuotes(); numbers.append(n); i += 1; continue }
            if let q = quoteMatch(line)  { flushPara(); flushBullets(); flushNumbers(); quotes.append(q); i += 1; continue }

            // Default: paragraph text (soft-break joins with following plain lines).
            flushBullets(); flushNumbers(); flushQuotes()
            para.append(line)
            i += 1
        }
        flushAll()
        return blocks
    }

    // MARK: - Line matchers

    private static func headingMatch(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let chars = Array(line)
        var level = 0
        while level < chars.count && chars[level] == "#" { level += 1 }
        guard (1...6).contains(level), level < chars.count, chars[level] == " " else { return nil }
        let text = String(chars[(level + 1)...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func bulletMatch(_ line: String) -> String? {
        let chars = Array(line)
        guard chars.count >= 2, chars[0] == "-" || chars[0] == "*", chars[1] == " " else { return nil }
        return String(chars[2...]).trimmingCharacters(in: .whitespaces)
    }

    private static func numberMatch(_ line: String) -> String? {
        let chars = Array(line)
        var k = 0
        while k < chars.count && chars[k].isNumber { k += 1 }
        guard k > 0, k + 1 < chars.count, chars[k] == ".", chars[k + 1] == " " else { return nil }
        return String(chars[(k + 2)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func quoteMatch(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        return line.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func tableCells(_ line: String) -> [String] {
        var parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MarkdownBlocksTests`
Expected: PASS — all tests green (including `testBundledHelpHasNoFallenThroughBlockMarkers`, since the current Help.md is within the subset).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Text/MarkdownBlocks.swift Tests/LiveAstroCoreTests/MarkdownBlocksTests.swift
git commit -m "feat: block-level markdown parser for Help (Foundation-only, TDD)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Rewrite `HelpView` to render `[MarkdownBlock]`

**Files:**
- Modify: `Sources/LiveAstroStudio/HelpView.swift` (full rewrite)

**Interfaces:**
- Consumes: `MarkdownBlocks.parse(_:) -> [MarkdownBlock]` and `MarkdownBlock` from `LiveAstroCore` (Task 1).
- Produces: nothing consumed by later tasks (leaf view). Task 3 relies only on the renderer supporting every `MarkdownBlock` case.

- [ ] **Step 1: Replace the file contents**

Overwrite `Sources/LiveAstroStudio/HelpView.swift`:

```swift
import SwiftUI
import LiveAstroCore

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var blocks: [MarkdownBlock] {
        guard let url = Bundle.module.url(forResource: "Help", withExtension: "md"),
              let md = try? String(contentsOf: url, encoding: .utf8)
        else { return [.paragraph("Help unavailable.")] }
        return MarkdownBlocks.parse(md)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)

        case let .paragraph(text):
            Text(inline(text))
                .fixedSize(horizontal: false, vertical: true)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).").monospacedDigit()
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .table(headers, rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                        Text(inline(h)).bold()
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 4)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary)
                    .frame(width: 3)
                Text(inline(text)).italic().fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }

    /// Interpret inline markdown only (bold/italic/code); block structure is
    /// already handled by MarkdownBlocks. Falls back to the raw string.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
```

- [ ] **Step 2: Build (debug) to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 3: Confirm the Core suite is still green**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all tests pass (no regressions; this task adds no Core tests).

- [ ] **Step 4: Manual visual check (RELEASE)**

Run: `swift build -c release`
Then launch the app, open Help, and confirm: headings render as sized/bold titles (not literal `#`), the Source Modes table renders as a real grid (not `| … |`), bullet and numbered lists render with markers, the OBS-password blockquote renders with an accent bar (not a leading `>`), `---` renders as divider lines, inline **bold**/*italic*/`code` are styled, and text is still selectable.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroStudio/HelpView.swift
git commit -m "feat: render Help with block-level markdown (headings, table, lists, quote, rules)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Refresh `Help.md` content for the current app

**Files:**
- Modify: `Sources/LiveAstroStudio/Resources/Help.md` (full rewrite)

**Interfaces:**
- Consumes: the renderer (Task 2) and parser (Task 1) — content must stay within the supported subset (headings, paragraphs, bullet/numbered lists, pipe tables, blockquotes, `---` rules, inline bold/italic/code; NO code fences).
- Produces: nothing.

- [ ] **Step 1: Replace Help.md with the refreshed content**

Overwrite `Sources/LiveAstroStudio/Resources/Help.md`:

```markdown
# LiveAstro Studio Help

LiveAstro Studio watches your incoming sub-exposures, stacks them live, and shows the result in an OBS-friendly window you can broadcast. It works with any FITS source — a Seestar, an ASIAIR/ASI2600 rig, or NINA — plus a native stacker for finished imaging.

---

## Quick Start

There are two one-tap live paths. Both relay only the subs that arrive **after** you tap (session-scoped), then stack them natively.

1. **Seestar Live** — mount the Seestar's SMB share in Finder, then tap **Seestar Live**. The app auto-detects the share, relays 10-second subs to a local folder, and begins stacking.
2. **Watch Folder Live** — tap **Watch Folder Live** and pick the folder your rig writes subs to (ASI2600/ASIAIR autorun folder, a NINA output folder, or any incoming-subs folder). The app relays new subs from that folder and stacks them.

Switch to the **Live** tab to watch the stack build in real time. Tap **Detach** to pop the display into its own window for OBS capture.

---

## Source Modes

| Mode | What it does |
|------|-------------|
| **Seestar Live** | Auto-detects the Seestar SMB share and stacks its 10s subs live. |
| **Watch Folder Live** | Relays new subs from a folder you pick (any rig) and stacks them live. |
| **Raw subs** | Imports and stacks a folder of existing sub-exposures with the native stacker. |

The source mode is locked while a session is running. End the session to change it.

---

## Display Adjustments

These sliders are **non-destructive** — they change only what you see, never the linear master on disk.

- **Black point** — lifts the shadow clip to darken the background.
- **Stretch strength** — how aggressively midtones are brightened.
- **Saturation** — color intensity of the display image.

Press **Reset** to return to neutral (the default, byte-identical to the unadjusted view). Two background tools help with light pollution:

- **Neutralize background** — removes an overall color cast (e.g. the green tint on one-shot-color sky).
- **Background extraction (DBE)** — fits and subtracts a smooth gradient across the frame.

---

## Zoom & Pan

Scroll over the live view to zoom in and out. Drag to pan when zoomed in. The view re-centers to fit when you zoom back out.

---

## Calibration

Calibration applies only in **Raw subs** mode.

- **Dark** — subtracts thermal noise matching your sub-exposure length and camera temperature.
- **Flat** — corrects vignetting and dust motes. Flats are bias-corrected before use.
- **Bias** — used internally to clean flats; it is *not* applied to light frames directly.

For each frame type you can either:

- **Use file…** — point to a pre-built master FITS file.
- **Build…** — select a folder of raw calibration frames; the app combines them into a master and saves it to `~/Library/Application Support/LiveAstroStudio/masters/`.

Leave a row empty to skip that calibration type.

---

## Go Live (YouTube via OBS)

LiveAstro Studio broadcasts through OBS Studio.

1. Connect LiveAstro to OBS in the **OBS** section (see OBS Setup below).
2. In OBS, add a source pointed at the detached LiveAstro window.
3. Click **Go Live** to start the stream. The status line shows elapsed time and, if the network is congested, dropped-frame and congestion readouts.
4. Click **End Broadcast** to stop.

Use the **Stack scene** / **Scope scene** pickers with **Scene automation** on to switch scenes automatically when the stack stalls.

---

## OBS Setup

1. In OBS: **Tools → WebSocket Server Settings** → enable the WebSocket server (default port 4455).
2. Copy the password from **Show Connect Info**.
3. Paste the host, port, and password into the **OBS** section in LiveAstro Studio, then click **Connect**.

> **Important:** The OBS WebSocket password regenerates every time OBS is restarted with "Generate Password" enabled. If the connection suddenly fails, open **Tools → WebSocket Server Settings → Show Connect Info** in OBS and paste the new password here.

---

## Troubleshooting

**"No share found" when tapping Seestar Live**
The Seestar SMB share is not mounted. In Finder: **Go → Connect to Server** (`⌘K`), enter `smb://<seestar-ip>`, and mount the share. Then try Seestar Live again.

**Watch Folder Live isn't stacking**
Confirm the folder you picked is the one your rig actively writes subs to, and that new `.fit`/`.fits` files are appearing there. Only subs that arrive after you tap are relayed; a folder that is already full but idle will not produce new frames.

**Stack not updating**
Check that the relay folder (`~/Library/Application Support/LiveAstroStudio/relay/`) is receiving new files. If it is empty, end the session, re-select the source, and start again.

**OBS scene not switching automatically**
Ensure you have selected both a **Stack scene** and a **Scope scene** in the OBS section and that **Scene automation** is toggled on.

**Import Subs progress bar stuck**
A large folder with many FITS files can take time. The **Cancel** button is always available; cancelling mid-import preserves all frames processed so far and leaves a valid partial master.
```

- [ ] **Step 2: Verify the refreshed content parses cleanly (regression guard)**

Run: `swift test --filter MarkdownBlocksTests/testBundledHelpHasNoFallenThroughBlockMarkers`
Expected: PASS — the rewritten Help.md fully parses; no block construct falls through to a literal-marker paragraph.

- [ ] **Step 3: Full Core suite green**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all tests pass.

- [ ] **Step 4: Manual visual check (RELEASE)**

Run: `swift build -c release`
Launch, open Help, scroll top to bottom. Confirm every section renders as structure (headings, the Source Modes table, the numbered Quick Start / Go Live / OBS steps, the bullet lists, the OBS-password blockquote, and the `---` dividers) with inline bold/italic/code styled, and no literal `#`, `|`, `>`, `-`, or `1.` markers visible.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroStudio/Resources/Help.md
git commit -m "docs: refresh Help.md for current app (Watch Folder Live, display adjustments, Go Live, zoom/pan)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- Block rendering (headings, paragraphs, lists, table, quote, rule) → Task 1 (parse) + Task 2 (render). ✅
- Inline bold/italic/code preserved → parser leaves verbatim (T1 `testInlineMarkupLeftVerbatimForRenderer`), renderer's `inline()` interprets (T2). ✅
- Content refresh covering current pillars → Task 3. ✅
- Parser is Foundation-only, unit-tested; rendering build/manual-verified → T1 tests, T2/T3 build+manual. ✅
- Zero external deps → parser is hand-rolled; no package added. ✅
- Regression guard (bundled Help.md fully parses) → T1 `testBundledHelpHasNoFallenThroughBlockMarkers`, re-run in T3. ✅
- `Text/` new group → T1 file path. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step shows the command + expected result. ✅

**3. Type consistency:** `MarkdownBlock` cases and `MarkdownBlocks.parse` signature are identical across T1 (definition), T2 (consumption in `view(for:)` switch — all seven cases handled), and T3 (subset constraint). Renderer's switch is exhaustive over the enum. ✅
