import XCTest
import LiveAstroCore
@testable import LiveAstroStudio

final class HelpCatalogTests: XCTestCase {
    private let manual = """
    # Manual
    Intro.
    ## Calibration
    Choose matched frames.
    ### Bias
    Removes readout offset.
    #### Technical detail
    Nested explanation.
    ## Troubleshooting
    Check the log.
    ### Dust remains
    Compare flats.
    """

    // Break: indexing only top-level headings makes contextual topics undiscoverable.
    func testIndexesTopicsWithoutTurningTechnicalDetailsIntoTopics() {
        let catalog = HelpCatalog(markdown: manual)
        XCTAssertEqual(catalog.topics.map(\.title), ["Calibration", "Bias", "Troubleshooting", "Dust remains"])
        XCTAssertEqual(catalog.topics.first { $0.title == "Bias" }?.parent, "Calibration")
    }

    // Break: title-only search or returning everything for a nonmatching query.
    func testSearchMatchesBodyCaseInsensitivelyAndRequiresAllWords() {
        let catalog = HelpCatalog(markdown: manual)
        XCTAssertEqual(catalog.search(" READOUT offset ").map(\.title), ["Bias"])
        XCTAssertTrue(catalog.search("readout telescope").isEmpty)
        XCTAssertEqual(catalog.search("  ").count, 4)
    }

    // Break: a nested topic leaks its next peer, or loses technical details.
    func testTopicContentPreservesNestedDetailsWithoutNextSection() {
        let topic = HelpCatalog(markdown: manual).topics.first { $0.title == "Bias" }
        XCTAssertEqual(topic?.blocks, [.heading(level: 3, text: "Bias"), .paragraph("Removes readout offset."),
                                      .heading(level: 4, text: "Technical detail"), .paragraph("Nested explanation.")])
    }

    func testEmptyManualHasNoInventedTopics() {
        XCTAssertTrue(HelpCatalog(markdown: "").topics.isEmpty)
    }

    // Break: folding a technical section also hides the following ordinary topic.
    func testTechnicalDetailsStopAtNextHeadingAndKeepAllContent() {
        let blocks: [MarkdownBlock] = [.paragraph("Short answer"),
            .heading(level: 4, text: "Technical detail"), .paragraph("Mechanism"),
            .heading(level: 3, text: "Next topic"), .paragraph("Next answer")]
        let parts = HelpCatalog.articleParts(blocks)
        XCTAssertEqual(parts.map(\.detailTitle), [nil, "Technical detail", nil])
        XCTAssertEqual(parts.map(\.blocks), [[.paragraph("Short answer")], [.paragraph("Mechanism")],
            [.heading(level: 3, text: "Next topic"), .paragraph("Next answer")]])
    }
}
