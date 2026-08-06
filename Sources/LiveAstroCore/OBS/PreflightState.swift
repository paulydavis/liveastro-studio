import Foundation

/// One link in the Go Live pre-flight chain (spec §1). Order matters:
/// `chainOrder` is the resume order for a halted Go Live.
public enum PreflightLink: String, CaseIterable, Sendable {
    case obsRunning, connected, sceneCapture, streamService, streaming
    public static let chainOrder: [PreflightLink] =
        [.obsRunning, .connected, .sceneCapture, .streamService, .streaming]
}

public enum PreflightLinkStatus: Equatable, Sendable {
    case unknown
    case checking
    case ok
    case failed(reason: String, remedy: String)
}

/// Published by `BroadcastController`; rendered dumbly by the status panel.
public struct PreflightState: Equatable, Sendable {
    private var statuses: [PreflightLink: PreflightLinkStatus]

    public init() {
        statuses = Dictionary(uniqueKeysWithValues:
            PreflightLink.allCases.map { ($0, .unknown) })
    }
    public subscript(_ link: PreflightLink) -> PreflightLinkStatus {
        statuses[link] ?? .unknown
    }
    public mutating func set(_ link: PreflightLink, _ status: PreflightLinkStatus) {
        statuses[link] = status
    }
    /// First link in chain order that is not `.ok` — where Go Live resumes.
    public var firstNonGreen: PreflightLink? {
        PreflightLink.chainOrder.first { self[$0] != .ok }
    }
    public mutating func reset() { self = PreflightState() }
}
