import Foundation

/// Non-destructive display-path adjustments layered on AutoStretch. Neutral
/// values reproduce the plain auto-stretch look exactly. Values are clamped to
/// their documented ranges when APPLIED (in AutoStretch / BackgroundExtraction),
/// not here — so a persisted out-of-range blob degrades gracefully.
///
/// - blackPoint:          0 (neutral) … 0.2  — shadow clip on the linear data
/// - midtoneStrength:     −1 … +1, 0 neutral — scales the auto-MTF midpoint
/// - saturation:          0 … 2, 1 neutral   — luminance-preserving chroma scale
/// - backgroundExtraction false neutral       — flatten the LP gradient (DBE)
/// - backgroundDegree:    1 planar / 2 quad   — DBE polynomial degree (clamped on apply)
public struct DisplayAdjustments: Equatable, Codable {
    public var blackPoint: Double
    public var midtoneStrength: Double
    public var saturation: Double
    public var backgroundExtraction: Bool
    public var backgroundDegree: Int

    public init(blackPoint: Double = 0, midtoneStrength: Double = 0, saturation: Double = 1,
                backgroundExtraction: Bool = false, backgroundDegree: Int = 1) {
        self.blackPoint = blackPoint
        self.midtoneStrength = midtoneStrength
        self.saturation = saturation
        self.backgroundExtraction = backgroundExtraction
        self.backgroundDegree = backgroundDegree
    }

    public static let neutral = DisplayAdjustments()

    // Custom decode so a settings blob written before the DBE fields existed
    // still decodes (missing keys → defaults). Encode stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case blackPoint, midtoneStrength, saturation, backgroundExtraction, backgroundDegree
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blackPoint = try c.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0
        midtoneStrength = try c.decodeIfPresent(Double.self, forKey: .midtoneStrength) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        backgroundExtraction = try c.decodeIfPresent(Bool.self, forKey: .backgroundExtraction) ?? false
        backgroundDegree = try c.decodeIfPresent(Int.self, forKey: .backgroundDegree) ?? 1
    }
}
