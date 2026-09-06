import CoreGraphics
import Foundation

/// A single resolved display state. Image provenance travels with the pixels so UI captions
/// cannot describe a newer refiner result than the one actually on screen.
public struct DisplayDelivery {
    public let revision: UInt64
    public let previewImage: CGImage?
    public let broadcastImage: CGImage?
    public let cleanMasterSubCount: Int?
    public let integrationSeconds: Double
    public let previewIntegrationSeconds: Double
    public let subExposureSeconds: Double
    public let record: SnapshotRecord?
}

/// Main-actor delivery boundary shared by the app and integration tests.
/// A new session invalidates all deliveries from its predecessor; an older render cannot
/// overwrite a newer image even when asynchronous main-actor hops arrive out of order.
@MainActor public final class DisplayPresentation {
    public private(set) var delivery: DisplayDelivery?
    private var sessionID: UUID?

    public init() {}

    public func begin(sessionID: UUID) {
        self.sessionID = sessionID
        delivery = nil
    }

    public func belongs(to sessionID: UUID) -> Bool { self.sessionID == sessionID }

    @discardableResult
    public func accept(_ update: DisplayDelivery, sessionID: UUID) -> Bool {
        guard self.sessionID == sessionID,
              delivery.map({ update.revision > $0.revision }) ?? true else { return false }
        delivery = update
        return true
    }
}
