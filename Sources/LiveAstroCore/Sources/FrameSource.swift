import Foundation

/// One raw (pre-debayer, stored row order) frame from any source (spec §4.1).
public struct RawFrame {
    public let image: AstroImage          // 1-channel CFA or mono, stored row order
    public let bayerPattern: BayerPattern?
    public let bottomUp: Bool             // FITS ROWORDER
    public let timestamp: Date
    public let sourceName: String

    public init(image: AstroImage, bayerPattern: BayerPattern?, bottomUp: Bool,
                timestamp: Date, sourceName: String) {
        self.image = image; self.bayerPattern = bayerPattern; self.bottomUp = bottomUp
        self.timestamp = timestamp; self.sourceName = sourceName
    }
}

/// A source of raw frames; implementations include folder import and live watch (spec §4.1).
public protocol FrameSource: AnyObject {
    /// Emits raw frames as available; finishes when the source ends (import) or stop() is called.
    var frames: AsyncStream<RawFrame> { get }
    /// True when the stream ends on its own (finite import); false for live sources.
    var isFinite: Bool { get }
    func start() throws
    func stop()
}
