import Foundation

/// One raw (pre-debayer, stored row order) frame from any source (spec §4.1).
public struct RawFrame {
    public let image: AstroImage          // 1-channel CFA or mono, stored row order
    public let bayerPattern: BayerPattern?
    public let bottomUp: Bool             // FITS ROWORDER
    public let timestamp: Date
    public let sourceName: String
    public let metadata: SourceMetadata?
    /// Content-digest identity (SHA-256 over the bytes actually loaded; stat fields zeroed and
    /// unused) of the on-disk file this frame was loaded from, captured at load time. Threaded
    /// through so a post-session re-stack can verify each recorded sub by CONTENT — not
    /// inode/mtime — and skip one whose bytes changed on disk since capture, rather than
    /// silently stacking different bytes. nil for frames not loaded from a file (in-memory/synthetic).
    public let identity: FileIdentity?

    public init(image: AstroImage, bayerPattern: BayerPattern?, bottomUp: Bool,
                timestamp: Date, sourceName: String, metadata: SourceMetadata? = nil,
                identity: FileIdentity? = nil) {
        self.image = image; self.bayerPattern = bayerPattern; self.bottomUp = bottomUp
        self.timestamp = timestamp; self.sourceName = sourceName
        self.metadata = metadata
        self.identity = identity
    }
}

/// A source of raw frames; implementations include folder import and live watch (spec §4.1).
public protocol FrameSource: AnyObject {
    /// Emits raw frames as available; finishes when the source ends (import) or stop() is called.
    var frames: AsyncStream<RawFrame> { get }
    /// True when the stream ends on its own (finite import); false for live sources.
    var isFinite: Bool { get }
    /// Total frames known up front (finite import); nil for live sources.
    var totalCount: Int? { get }
    func start() throws
    func stop()
}

public enum FrameSourceActivity: Equatable {
    case beginFrameRead(String)
    case endFrameRead(String)
}

public protocol FrameSourceActivityReporting: AnyObject {
    var onActivity: ((FrameSourceActivity) -> Void)? { get set }
}
