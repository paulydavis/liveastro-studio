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
