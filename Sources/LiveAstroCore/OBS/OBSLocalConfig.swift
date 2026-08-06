import Foundation

/// Read-only view of OBS's local WebSocket server config (spec §3). The app
/// NEVER writes this file. `read` returns nil for absent/unreadable/corrupt
/// files — callers fall back to the manual host/port/password fields.
public struct OBSLocalConfig: Equatable {
    public var serverEnabled: Bool
    public var port: Int
    public var password: String?

    public init(serverEnabled: Bool, port: Int, password: String?) {
        self.serverEnabled = serverEnabled
        self.port = port
        self.password = password
    }

    /// `~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json`
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
    }

    public static func read(from url: URL = defaultURL) -> OBSLocalConfig? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return OBSLocalConfig(
            serverEnabled: dict["server_enabled"] as? Bool ?? false,
            port: dict["server_port"] as? Int ?? 4455,
            password: dict["server_password"] as? String)
    }
}
