import XCTest
@testable import LiveAstroCore

final class OBSMessageTests: XCTestCase {

    // MARK: - Encode: Identify (op 1)

    func testEncodeIdentifyWithAuth() throws {
        let json = OBSMessage.identify(rpcVersion: 1,
                                       auth: "someAuthString",
                                       eventSubscriptions: 33)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["op"] as? Int, 1)
        let d = try XCTUnwrap(obj["d"] as? [String: Any])
        XCTAssertEqual(d["rpcVersion"] as? Int, 1)
        XCTAssertEqual(d["authentication"] as? String, "someAuthString")
        XCTAssertEqual(d["eventSubscriptions"] as? Int, 33)
    }

    func testEncodeIdentifyNoAuth() throws {
        let json = OBSMessage.identify(rpcVersion: 1,
                                       auth: nil,
                                       eventSubscriptions: 0)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["op"] as? Int, 1)
        let d = try XCTUnwrap(obj["d"] as? [String: Any])
        XCTAssertNil(d["authentication"])
        XCTAssertEqual(d["eventSubscriptions"] as? Int, 0)
    }

    func testEncodeRequest() throws {
        let json = OBSMessage.request(type: "GetVersion", id: "req-1", data: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["op"] as? Int, 6)
        let d = try XCTUnwrap(obj["d"] as? [String: Any])
        XCTAssertEqual(d["requestType"] as? String, "GetVersion")
        XCTAssertEqual(d["requestId"] as? String, "req-1")
    }

    func testEncodeRequestWithData() throws {
        let json = OBSMessage.request(type: "SetCurrentScene", id: "req-2",
                                      data: ["sceneName": "Main"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["op"] as? Int, 6)
        let d = try XCTUnwrap(obj["d"] as? [String: Any])
        let rd = try XCTUnwrap(d["requestData"] as? [String: Any])
        XCTAssertEqual(rd["sceneName"] as? String, "Main")
    }

    // MARK: - Decode: Hello (op 0) with authentication

    func testParseHelloWithAuth() throws {
        let fixture = """
        {"op":0,"d":{"obsWebSocketVersion":"5.5.0","rpcVersion":1,"authentication":{"challenge":"ztTBnnuqrqaKDzRM3xcVdbYm","salt":"PZVbYpvAnZut2SS6JNJytDm9"}}}
        """
        let frame = try XCTUnwrap(OBSMessage.parse(fixture))
        guard case .hello(let hello) = frame else {
            XCTFail("Expected .hello, got \(frame)")
            return
        }
        XCTAssertEqual(hello.rpcVersion, 1)
        let auth = try XCTUnwrap(hello.authentication)
        XCTAssertEqual(auth.challenge, "ztTBnnuqrqaKDzRM3xcVdbYm")
        XCTAssertEqual(auth.salt, "PZVbYpvAnZut2SS6JNJytDm9")
    }

    // MARK: - Decode: Hello (op 0) without authentication (no-password OBS)

    func testParseHelloNoAuth() throws {
        let fixture = """
        {"op":0,"d":{"obsWebSocketVersion":"5.5.0","rpcVersion":1}}
        """
        let frame = try XCTUnwrap(OBSMessage.parse(fixture))
        guard case .hello(let hello) = frame else {
            XCTFail("Expected .hello, got \(frame)")
            return
        }
        XCTAssertEqual(hello.rpcVersion, 1)
        XCTAssertNil(hello.authentication)
    }

    // MARK: - Decode: Identified (op 2)

    func testParseIdentified() throws {
        let fixture = """
        {"op":2,"d":{"negotiatedRpcVersion":1}}
        """
        let frame = try XCTUnwrap(OBSMessage.parse(fixture))
        guard case .identified = frame else {
            XCTFail("Expected .identified, got \(frame)")
            return
        }
    }

    // MARK: - Decode: RequestResponse (op 7)

    func testParseRequestResponse() throws {
        let fixture = """
        {"op":7,"d":{"requestType":"GetVersion","requestId":"abc","requestStatus":{"result":true,"code":100},"responseData":{"obsVersion":"30.0.0"}}}
        """
        let frame = try XCTUnwrap(OBSMessage.parse(fixture))
        guard case .response(let resp) = frame else {
            XCTFail("Expected .response, got \(frame)")
            return
        }
        XCTAssertEqual(resp.requestId, "abc")
        XCTAssertEqual(resp.requestType, "GetVersion")
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.code, 100)
        XCTAssertNil(resp.comment)
        XCTAssertEqual(resp.responseData["obsVersion"] as? String, "30.0.0")
    }

    func testParseRequestResponseWithComment() throws {
        let fixture = """
        {"op":7,"d":{"requestType":"BadCall","requestId":"xyz","requestStatus":{"result":false,"code":604,"comment":"Not found"},"responseData":{}}}
        """
        let frame = try XCTUnwrap(OBSMessage.parse(fixture))
        guard case .response(let resp) = frame else {
            XCTFail("Expected .response, got \(frame)")
            return
        }
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.code, 604)
        XCTAssertEqual(resp.comment, "Not found")
    }

    // MARK: - Decode: Event (op 5)

    func testParseEvent() throws {
        let fixture = """
        {"op":5,"d":{"eventType":"StreamStateChanged","eventIntent":64,"eventData":{"outputActive":true}}}
        """
        let frame = try XCTUnwrap(OBSMessage.parse(fixture))
        guard case .event(let type, let data) = frame else {
            XCTFail("Expected .event, got \(frame)")
            return
        }
        XCTAssertEqual(type, "StreamStateChanged")
        XCTAssertEqual(data["outputActive"] as? Bool, true)
    }

    // MARK: - Decode: unknown opcode

    func testParseUnknown() throws {
        let fixture = """
        {"op":99,"d":{}}
        """
        let frame = try XCTUnwrap(OBSMessage.parse(fixture))
        guard case .unknown = frame else {
            XCTFail("Expected .unknown, got \(frame)")
            return
        }
    }

    func testParseInvalidJSON() {
        XCTAssertNil(OBSMessage.parse("not json at all"))
    }
}
