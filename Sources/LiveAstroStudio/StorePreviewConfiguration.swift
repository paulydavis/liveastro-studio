import Foundation

enum DistributionKind: String, Sendable {
    case direct
    case storePreview
    case appStore
}

/// Bundle-selected distribution defaults. In a sandboxed app, Application Support
/// resolves inside its own container; injected roots keep fixture storage isolated.
struct StorePreviewConfiguration: Sendable {
    let distribution: DistributionKind
    var isStorePreview: Bool { distribution == .storePreview }
    var isSandboxedDistribution: Bool { distribution != .direct }
    var supportsExternalProcessor: Bool { distribution == .direct }
    var supportsPublicStreamAutomation: Bool { distribution == .direct }
    var supportsSceneAutomation: Bool { distribution == .direct }
    var supportsOBSStatus: Bool { true }
    var supportsOBSLocalRecording: Bool { isSandboxedDistribution }
    let containerRoot: URL
    var relayRoot: URL {
        isSandboxedDistribution ? containerRoot.appendingPathComponent("relay", isDirectory: true)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LiveAstro/relay", isDirectory: true)
    }
    var libraryRoot: URL? { isSandboxedDistribution ? containerRoot.appendingPathComponent("calibration", isDirectory: true) : nil }
    var catalogRoot: URL { containerRoot.appendingPathComponent("catalog", isDirectory: true) }
    var catalogURL: URL? { isSandboxedDistribution ? catalogRoot.appendingPathComponent("brightstars.bin") : nil }
    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier, containerRoot: URL? = nil) {
        switch bundleIdentifier {
        case "com.pauldavis.liveastrostudio.store-preview": distribution = .storePreview
        case "com.pauldavis.liveastrostudio.appstore": distribution = .appStore
        default: distribution = .direct
        }
        self.containerRoot = containerRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstroStudio", isDirectory: true)
    }
}
