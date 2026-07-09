import Foundation

/// Transforms an incoming warped frame before it is accumulated, updating its own
/// per-pixel running state. Reference type (holds mutable state).
public protocol RejectionMethod: AnyObject {
    /// Returns the frame to accumulate. Only pixels where `mask[i] > 0` are treated
    /// as in-bounds (stats updated + clamped there); other pixels pass through.
    func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage
    /// Discard all accumulated per-pixel state (called from StackEngine.reseed()).
    func reset()
}

/// Pass-through — preserves today's behavior exactly.
public final class NoRejection: RejectionMethod {
    public init() {}
    public func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage { frame }
    public func reset() {}
}

/// UI strength → κ (sigma multiplier). Higher κ = safer (rejects less).
public enum RejectionStrength: String, CaseIterable, Codable {
    case low, medium, high
    public var kappa: Float {
        switch self {
        case .low:    return 3.5
        case .medium: return 3.0
        case .high:   return 2.5
        }
    }
}
