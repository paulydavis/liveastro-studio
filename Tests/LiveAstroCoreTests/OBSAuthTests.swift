import XCTest
import CryptoKit
@testable import LiveAstroCore

final class OBSAuthTests: XCTestCase {
    func testKnownVector() {
        // password "supersecretpassword", salt "PZVbYpvAnZut2SS6JNJytDm9",
        // challenge "ztTBnnuqrqaKDzRM3xcVdbYm" — obs-websocket 5.x spec example.
        // Expected value verified via:
        // python3 -c "import hashlib,base64; s=base64.b64encode(hashlib.sha256(
        //   ('supersecretpassword'+'PZVbYpvAnZut2SS6JNJytDm9').encode()).digest());
        //   print(base64.b64encode(hashlib.sha256(
        //   s+'ztTBnnuqrqaKDzRM3xcVdbYm'.encode()).digest()).decode())"
        // → zZgWipvwSGrw748kHN4gNpBC1IaeiiWX3Hjkrm849Sc=
        let auth = OBSAuth.authString(password: "supersecretpassword",
                                      salt: "PZVbYpvAnZut2SS6JNJytDm9",
                                      challenge: "ztTBnnuqrqaKDzRM3xcVdbYm")
        XCTAssertEqual(auth, "zZgWipvwSGrw748kHN4gNpBC1IaeiiWX3Hjkrm849Sc=")
    }

    func testDeterministic() {
        let a = OBSAuth.authString(password: "p", salt: "s", challenge: "c")
        let b = OBSAuth.authString(password: "p", salt: "s", challenge: "c")
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }
}
