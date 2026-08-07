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

    // MARK: - OAuth account-linked stream services (spec §3, amended 2026-08-06)

    /// The stream-service sections OBS writes OAuth link tokens into.
    private static let linkedServiceSections = ["YouTube", "Twitch", "Restream"]

    /// True when the ACTIVE OBS profile carries an OAuth account link for any
    /// stream service — the live-smoke gap: an account-linked service stores
    /// NO key in the service settings, so key-presence alone reads a working
    /// setup as red. The link's tokens live in the active profile's
    /// `basic.ini` under `[YouTube]`/`[Twitch]`/`[Restream]`.
    ///
    /// Presence only, same hygiene as the WebSocket password and the stream
    /// key: the token VALUE is never stored, returned, or logged — this
    /// function returns only Bool and contains no logging.
    ///
    /// Active profile resolution: `global.ini` → `[Basic]` → `ProfileDir`;
    /// with global.ini (or the key) missing, fall back to the single
    /// directory under `basic/profiles/` if exactly ONE exists — an ambiguous
    /// tree is never guessed at. Any unreadable/absent file → false.
    ///
    /// `obsRoot` defaults to the real `~/Library/Application Support/obs-studio`;
    /// tests point it at a fixture tree.
    public static func activeProfileHasLinkedAccount(obsRoot: URL? = nil) -> Bool {
        let root = obsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio")
        let profilesDir = root.appendingPathComponent("basic/profiles")

        var profileDir = iniValue(fileAt: root.appendingPathComponent("global.ini"),
                                  section: "Basic", key: "ProfileDir")
        if profileDir == nil {
            let dirs = ((try? FileManager.default.contentsOfDirectory(
                at: profilesDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard dirs.count == 1 else { return false }
            profileDir = dirs[0].lastPathComponent
        }
        guard let dir = profileDir, !dir.isEmpty else { return false }

        let basicINI = profilesDir.appendingPathComponent(dir)
            .appendingPathComponent("basic.ini")
        return linkedServiceSections.contains { section in
            // Mapped straight to Bool: the token value never escapes this line.
            iniValue(fileAt: basicINI, section: section, key: "RefreshToken")
                .map { !$0.isEmpty } ?? false
        }
    }

    /// Minimal line-based INI lookup: section headers `[Name]`, entries
    /// `Key=Value` (first `=` splits; whitespace trimmed; `\r\n` tolerated;
    /// a leading UTF-8 BOM — which OBS writes — is stripped). Returns nil for
    /// an absent/unreadable file or a missing section/key.
    private static func iniValue(fileAt url: URL, section: String, key: String) -> String? {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var inSection = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                inSection = String(line.dropFirst().dropLast()) == section
            } else if inSection, let eq = line.firstIndex(of: "=") {
                if line[..<eq].trimmingCharacters(in: .whitespaces) == key {
                    return line[line.index(after: eq)...]
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}
