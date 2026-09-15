import XCTest
@testable import LiveAstroStudio
import LiveAstroCore

final class HelpSectionTests: XCTestCase {
    // Break: a linked topic is missing from the bundled manual, or opens another section.
    func testSettingTopicsResolveToBundledExplanations() {
        let titles = ["Neutralize background (OSC white balance)", "Reject outliers (σ-clip)",
                      "Weight frames by quality", "Match sky background", "Match transparency",
                      "Keep relay sessions", "Debayer", "Live trail rejection (broadcast master)",
                      "Idle safeguard — save master if capture stalls", "Auto-stop at a set time",
                      "Red screen", "Flatten background (DBE)", "North up", "Black point",
                      "Stretch strength", "Saturation", "Denoise"]
        for title in titles {
            let blocks = HelpView(sectionTitle: title).blocks
            guard case let .heading(_, actualTitle) = blocks.first else {
                XCTFail("Missing bundled help for \(title)")
                continue
            }
            XCTAssertEqual(actualTitle, title)
            XCTAssertGreaterThan(blocks.count, 1, "Empty explanation: \(title)")
        }
    }
    // Break: showing the whole manual, dropping nested content, or leaking the next topic.
    func testFocusedHelpIncludesNestedContentButStopsAtNextPeerHeading() {
        let markdown = """
        # Manual
        Intro.
        ## Calibration
        General advice.
        ### Offset
        Explanation.
        #### Details
        More detail.
        ### Next topic
        Unrelated.
        """
        let result = HelpView.sectionBlocks(in: MarkdownBlocks.parse(markdown), title: "Offset")
        XCTAssertEqual(result, [.heading(level: 3, text: "Offset"), .paragraph("Explanation."),
                                .heading(level: 4, text: "Details"), .paragraph("More detail.")])
    }
    func testMissingHelpSectionIsExplicitInsteadOfWrongTopic() {
        let result = HelpView.sectionBlocks(in: [.heading(level: 2, text: "Elsewhere")], title: "Missing")
        XCTAssertEqual(result, [.paragraph("This help topic is unavailable.")])
    }
}
