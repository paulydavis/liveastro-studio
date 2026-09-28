import AppKit
import LiveAstroCore

@MainActor
final class CameraShareAuthorization {
    private let locations: AuthorizedLocations
    private let choose: @MainActor (CameraShareKind) -> URL?
    private let acquireSaved: @MainActor (String) async throws -> FileAccessLease

    init(locations: AuthorizedLocations,
         acquireSaved: (@MainActor (String) async throws -> FileAccessLease)? = nil,
         choose: @escaping @MainActor (CameraShareKind) -> URL? = CameraShareAuthorization.chooseFolder) {
        self.locations = locations
        self.choose = choose
        self.acquireSaved = acquireSaved ?? { try await locations.acquire(key: $0) }
    }

    func acquire(_ kind: CameraShareKind, replacing: Bool = false) async throws -> FileAccessLease? {
        let key = "camera:" + kind.rawValue
        if !replacing, locations.displayURL(key: key) != nil { return try await acquireSaved(key) }
        guard let selected = choose(kind) else { return nil }
        return try await locations.select(selected, key: key)
    }

    private static func chooseFolder(_ kind: CameraShareKind) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose \(kind.displayName) share"
        panel.message = "Mount the camera share in Finder first, then select its top-level folder. LiveAstro remembers permission to search only inside this folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
