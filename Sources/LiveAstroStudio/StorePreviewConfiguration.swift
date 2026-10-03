import Foundation

/// Bundle-selected distribution defaults. In a sandboxed app, Application Support
/// resolves inside its own container; injected roots keep fixture storage isolated.
struct StorePreviewConfiguration: Sendable {
    let isStorePreview: Bool
    let containerRoot: URL
    var relayRoot: URL {
        isStorePreview ? containerRoot.appendingPathComponent("relay", isDirectory: true)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LiveAstro/relay", isDirectory: true)
    }
    var libraryRoot: URL? { isStorePreview ? containerRoot.appendingPathComponent("calibration", isDirectory: true) : nil }
    var catalogRoot: URL { containerRoot.appendingPathComponent("catalog", isDirectory: true) }
    var catalogURL: URL? { isStorePreview ? catalogRoot.appendingPathComponent("brightstars.bin") : nil }
    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier, containerRoot: URL? = nil) {
        isStorePreview = bundleIdentifier == "com.pauldavis.liveastrostudio.store-preview"
        self.containerRoot = containerRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstroStudio", isDirectory: true)
    }
}
