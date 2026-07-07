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
