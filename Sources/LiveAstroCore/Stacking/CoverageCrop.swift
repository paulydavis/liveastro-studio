import Foundation

/// Inclusive pixel bounds of a rectangular crop region.
public struct CropRect: Equatable {
    public let x0: Int, y0: Int, x1: Int, y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }
    public var width: Int { x1 - x0 + 1 }
    public var height: Int { y1 - y0 + 1 }
}
