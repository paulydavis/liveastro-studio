# Help Markdown Renderer + Content Refresh — Design

**Date:** 2026-07-12
**Branch:** `feature/help-markdown-renderer` (off `main` @ 64dc8d6)
**Status:** approved for planning

## Problem

`HelpView` renders `Help.md` through `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)`, which only interprets **inline** markdown (bold, italic, code spans, links). Every **block-level** construct — `#`/`##` headings, the pipe table, bullet and numbered lists, the `>` blockquote, and `---` rules — falls through and renders as literal text. This has been a long-standing ledgered annoyance (M7). Additionally, the help content is Seestar-centric and predates the pillars shipped this session (Watch Folder Live, Go Live to YouTube via OBS, display adjustments, native background extraction/DBE, zoom/pan, live-session accuracy).

## Goals

1. Render `Help.md` with correct block-level structure — headings, paragraphs, bullet/numbered lists, a pipe table, blockquotes, and horizontal rules — while preserving inline **bold**/*italic*/`code`.
2. Refresh `Help.md` content to reflect the current app (all source modes and the pillars shipped this session).
3. No new external dependencies. Parser is pure, Foundation-only, and unit-tested; rendering is SwiftUI, build/manual-verified (matching the established house pattern).

## Non-Goals

- Not a full CommonMark implementation. Parse only the block constructs `Help.md` actually uses (YAGNI). No nested lists, no code fences, no images, no reference links, no setext headings.
- No live/interactive help, no search, no theming beyond matching existing app idioms.

## Architecture

Split **parsing (testable logic)** from **rendering (UI)**:

### 1. Parser — `Sources/LiveAstroCore/Text/MarkdownBlocks.swift` (NEW, Foundation-only, unit-tested)

```swift
public enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)     // level clamped 1...6
    case paragraph(String)
    case bulletList([String])                  // item inline-markdown text, marker stripped
    case numberedList([String])                // item inline-markdown text, "N." stripped; renderer re-numbers
    case table(headers: [String], rows: [[String]])
    case quote(String)                         // consecutive `>` lines joined with " "
    case rule
}

public enum MarkdownBlocks {
    /// Parse a limited markdown subset into block elements. Inline markdown
    /// inside each block's text is left intact for the renderer to interpret.
    public static func parse(_ markdown: String) -> [MarkdownBlock]
}
```

**Parsing rules (line-oriented, exactly the constructs Help.md uses):**

- **Heading:** a line matching `^(#{1,6})\s+(.*)$` → `.heading(level: min(count,6), text: rest.trimmed)`.
- **Rule:** a line that is exactly `---` (after trim) → `.rule`.
- **Table:** a `|`-leading line, followed by a separator line matching `^\|?[\s:|-]+\|?$` containing `-`, followed by zero+ `|` data lines. Cells = split on `|`, trim, drop the empty first/last produced by leading/trailing pipes. First `|` line = headers; data lines = rows. A `|` line NOT followed by a separator row is treated as a paragraph (defensive; Help.md always has the separator).
- **Bullet list:** consecutive lines matching `^[-*]\s+(.*)$` → one `.bulletList`, marker stripped.
- **Numbered list:** consecutive lines matching `^\d+\.\s+(.*)$` → one `.numberedList`, `N.` stripped. (Renderer displays sequential `1. 2. 3.` so source numbering need not be contiguous.)
- **Blockquote:** consecutive lines matching `^>\s?(.*)$` → one `.quote`, joined with a single space.
- **Blank line:** flushes the current open block (paragraph/list accumulation).
- **Paragraph:** any other non-blank line; consecutive plain lines join into one `.paragraph` with a single space (markdown soft-break semantics).

Ordering within a run is preserved. Bullet vs numbered are distinct runs (a switch flushes).

### 2. Renderer — `Sources/LiveAstroStudio/HelpView.swift` (REWRITE, app target, build-verified)

`HelpView` loads `Help.md`, calls `MarkdownBlocks.parse`, and renders `[MarkdownBlock]` in a `VStack(alignment: .leading, spacing: …)` inside the existing `ScrollView`, `.textSelection(.enabled)` preserved:

- **heading:** `Text(inline(text))` with `.font` by level — 1 → `.title.bold()`, 2 → `.title2.bold()`, 3 → `.headline`, else `.subheadline.bold()`; top padding for visual separation.
- **paragraph:** `Text(inline(text))`, `.fixedSize(horizontal: false, vertical: true)`.
- **bulletList / numberedList:** `VStack`, each item an `HStack(alignment: .firstTextBaseline)` of the marker (`•` or `"\(i+1)."`) + `Text(inline(item))`.
- **table:** SwiftUI `Grid` — a bold header `GridRow`, a `Divider()`, then a `GridRow` per data row; cells `Text(inline(cell))`, `.gridColumnAlignment(.leading)`.
- **quote:** `HStack` of a thin accent `RoundedRectangle` (~3pt, `.secondary`) + `Text(inline(text)).italic()`, with subtle padding/background.
- **rule:** `Divider().padding(.vertical, …)`.

`inline(_:)` is a private helper: `(try? AttributedString(markdown: $0, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString($0)` — same inline interpretation as today, now applied per block. The load-failure fallback (missing/unreadable `Help.md`) still shows a plain "Help unavailable." message.

### 3. Content refresh — `Sources/LiveAstroStudio/Resources/Help.md` (REWRITE)

Rewrite so the help reflects the current app. Sections:

- **Quick Start** — the two one-tap live paths: **Seestar Live** (travel rig) and **Watch Folder Live** (pick the folder your rig — ASI2600/ASIAIR/NINA — writes subs to; session-scoped relay + native stacking).
- **Source Modes** — table: Seestar Live, Watch Folder Live, Raw subs (import). Note mode is locked while a session runs.
- **Display Adjustments** — the non-destructive sliders (black point, stretch strength, saturation) + Reset; note the linear master is never modified; background neutralization + DBE (background extraction) toggles.
- **Zoom & Pan** — scroll to zoom over the live view, drag to pan, fit reset.
- **Calibration** — Dark/Flat/Bias, Use file / Build, masters location (Raw subs mode).
- **Go Live (YouTube via OBS)** — connect to OBS WebSocket, add a source pointed at the detached window, scene automation on stall, the congestion/dropped readout, Go Live / End Broadcast.
- **OBS Setup** — WebSocket server enable, password-regenerates warning (keep the blockquote).
- **Troubleshooting** — refreshed for both live paths (no share found, stack not updating / relay folder, OBS scene switching, import progress).

Content stays within the parser's supported subset (headings, paragraphs, one+ tables, bullet/numbered lists, blockquotes, rules, inline bold/italic/code). No code fences.

## Testing

**Parser (TDD, `Tests/LiveAstroCoreTests/MarkdownBlocksTests.swift`):**

- heading levels 1–3 and `>6` clamp; text trimmed.
- `---` → `.rule`; a `---` inside no other context is a rule, not a paragraph.
- table: headers + rows parsed, separator row consumed (not emitted), leading/trailing pipe empties dropped, cell trim.
- bullet run groups into one `.bulletList`; `-` and `*` both recognized; marker stripped.
- numbered run groups into one `.numberedList`; `N.` stripped; non-contiguous source numbers still one list.
- blockquote: consecutive `>` lines joined; `> ` prefix stripped.
- blank line flushes; two paragraphs separated by a blank line → two `.paragraph`; consecutive plain lines → one `.paragraph`.
- inline markup (`**bold**`, `` `code` ``) is left in the block text verbatim (renderer interprets it), i.e. parser does not strip/alter inline syntax.
- end-to-end: parsing the real bundled `Help.md` yields no `.paragraph` whose text still begins with an unconsumed block marker (`#`, `|`, `>`, `- `, `1. `) — guards against a construct silently falling through to literal text (the original bug).

**Renderer + content (build/manual-verified RELEASE, per house pattern):** `swift build -c release`; launch, open Help, visually confirm headings/table/lists/quote/rules render as structure (not literal `#`/`|`/`>`), inline bold/italic/code intact, text still selectable.

## Global Constraints

- Swift 5.10, macOS 14+.
- `LiveAstroCore` may import Foundation / CoreGraphics / Accelerate only. `MarkdownBlocks` uses Foundation only.
- Zero external dependencies (no swift-markdown, no MarkdownUI).
- Core tests run via `swift test --filter LiveAstroCoreTests`.
- Parser is TDD'd; app/UI is build/manual-verified (no XCTest for SwiftUI, same as prior pillars).
- `Text/` is a new group under `Sources/LiveAstroCore/`.

## Task Order (for the plan)

1. **T1 — `MarkdownBlock` enum + `MarkdownBlocks.parse` (TDD).** The parser and all parser tests. Independently testable; the shared interface every consumer depends on.
2. **T2 — `HelpView` rewrite to render `[MarkdownBlock]` (build-verified).** Depends on T1's API.
3. **T3 — `Help.md` content refresh (build-verified + parser round-trip assertion).** Rewrite content within the supported subset; the T1 end-to-end test asserts the bundled file fully parses with no fallen-through markers.
