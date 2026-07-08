import Foundation

// MARK: - Op codes

public enum OBSOpCode: Int {
    case hello = 0
    case identify = 1
    case identified = 2
    case event = 5
    case request = 6
    case requestResponse = 7
}

// MARK: - Fixed-shape Codable structs for incoming frames

/// Payload of op 0 (Hello).
public struct OBSHello: Decodable {
    public struct Auth: Decodable {
        public let challenge: String
        public let salt: String
    }
    public let rpcVersion: Int
    public let authentication: Auth?          // absent when OBS has no password
}

/// Parsed op 7 (RequestResponse) payload.
public struct OBSRequestResponse {
    public let requestId: String
    public let requestType: String
    public let ok: Bool
    public let code: Int
    public let comment: String?
    public let responseData: [String: Any]
}

// MARK: - Parsed frame enum

public enum ParsedFrame {
    case hello(OBSHello)
    case identified
    case event(type: String, data: [String: Any])
    case response(OBSRequestResponse)
    case unknown
}

// MARK: - OBSMessage encode/decode

public enum OBSMessage {

    // MARK: Encode

    /// Build an op 1 Identify frame.
    public static func identify(rpcVersion: Int,
                                auth: String?,
                                eventSubscriptions: Int) -> String {
        var d: [String: Any] = [
            "rpcVersion": rpcVersion,
            "eventSubscriptions": eventSubscriptions
        ]
        if let auth {
            d["authentication"] = auth
        }
        return encode(op: OBSOpCode.identify.rawValue, d: d)
    }

    /// Build an op 6 Request frame.
    public static func request(type: String,
                               id: String,
                               data: [String: Any]?) -> String {
        var d: [String: Any] = [
            "requestType": type,
            "requestId": id
        ]
        if let data {
            d["requestData"] = data
        }
        return encode(op: OBSOpCode.request.rawValue, d: d)
    }

    // MARK: Decode

    /// Parse an obs-websocket 5.x JSON text frame.
    /// Returns nil if the text is not valid JSON or lacks the required `op` key.
    public static func parse(_ text: String) -> ParsedFrame? {
        guard
            let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let op = obj["op"] as? Int
        else { return nil }

        switch OBSOpCode(rawValue: op) {
        case .hello:
            guard let dVal = obj["d"] else { return .unknown }
            do {
                let dData = try JSONSerialization.data(withJSONObject: dVal)
                let hello = try JSONDecoder().decode(OBSHello.self, from: dData)
                return .hello(hello)
            } catch {
                return .unknown
            }

        case .identified:
            return .identified

        case .event:
            guard let d = obj["d"] as? [String: Any],
                  let eventType = d["eventType"] as? String else { return .unknown }
            let eventData = d["eventData"] as? [String: Any] ?? [:]
            return .event(type: eventType, data: eventData)

        case .requestResponse:
            guard
                let d = obj["d"] as? [String: Any],
                let requestId = d["requestId"] as? String,
                let requestType = d["requestType"] as? String,
                let status = d["requestStatus"] as? [String: Any],
                let result = status["result"] as? Bool,
                let code = status["code"] as? Int
            else { return .unknown }
            let comment = status["comment"] as? String
            let responseData = d["responseData"] as? [String: Any] ?? [:]
            return .response(OBSRequestResponse(
                requestId: requestId,
                requestType: requestType,
                ok: result,
                code: code,
                comment: comment,
                responseData: responseData
            ))

        case .identify, .request, .none:
            return .unknown
        }
    }

    // MARK: Private helpers

    private static func encode(op: Int, d: [String: Any]) -> String {
        let envelope: [String: Any] = ["op": op, "d": d]
        guard
            let data = try? JSONSerialization.data(withJSONObject: envelope),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
