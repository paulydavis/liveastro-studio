import Foundation
import CryptoKit

/// obs-websocket 5.x authentication (spec §3):
/// base64( sha256( base64(sha256(password + salt)) + challenge ) )
public enum OBSAuth {
    public static func authString(password: String, salt: String, challenge: String) -> String {
        let secret = base64Sha256(password + salt)
        return base64Sha256(secret + challenge)
    }

    private static func base64Sha256(_ s: String) -> String {
        Data(SHA256.hash(data: Data(s.utf8))).base64EncodedString()
    }
}
