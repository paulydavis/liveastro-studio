import Foundation

/// Non-destructive display-path adjustments layered on AutoStretch. Neutral
/// values reproduce the plain auto-stretch look exactly. Values are clamped to
/// their documented ranges when APPLIED (in AutoStretch), not here — so a
/// persisted out-of-range blob degrades gracefully rather than being rewritten.
///
/// - blackPoint:      0 (neutral) … 0.2  — shadow clip on the linear data
/// - midtoneStrength: −1 … +1, 0 neutral — scales the auto-MTF midpoint
/// - saturation:      0 … 2, 1 neutral   — luminance-preserving chroma scale
public struct DisplayAdjustments: Equatable, Codable {
    public var blackPoint: Double
    public var midtoneStrength: Double
    public var saturation: Double

    public init(blackPoint: Double = 0, midtoneStrength: Double = 0, saturation: Double = 1) {
        self.blackPoint = blackPoint
        self.midtoneStrength = midtoneStrength
        self.saturation = saturation
    }

    public static let neutral = DisplayAdjustments(blackPoint: 0, midtoneStrength: 0, saturation: 1)
}
