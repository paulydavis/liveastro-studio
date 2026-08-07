import XCTest
@testable import LiveAstroCore

final class PreflightStateTests: XCTestCase {
    func testInitAllUnknown() {
        let s = PreflightState()
        for link in PreflightLink.allCases { XCTAssertEqual(s[link], .unknown) }
    }
    func testFirstNonGreenFollowsChainOrder() {
        var s = PreflightState()
        XCTAssertEqual(s.firstNonGreen, .obsRunning)
        s.set(.obsRunning, .ok); s.set(.connected, .ok)
        XCTAssertEqual(s.firstNonGreen, .sceneCapture)
        s.set(.sceneCapture, .failed(reason: "no capture", remedy: "run Go Live"))
        XCTAssertEqual(s.firstNonGreen, .sceneCapture)
        for link in PreflightLink.allCases { s.set(link, .ok) }
        XCTAssertNil(s.firstNonGreen)
    }
    func testResetReturnsAllUnknown() {
        var s = PreflightState()
        s.set(.streaming, .ok)
        s.reset()
        XCTAssertEqual(s, PreflightState())
    }
    func testChainOrderIsCompleteAndStable() {
        XCTAssertEqual(PreflightLink.chainOrder,
                       [.obsRunning, .connected, .sceneCapture, .streamService, .streaming])
        XCTAssertEqual(Set(PreflightLink.chainOrder), Set(PreflightLink.allCases))
    }
}
