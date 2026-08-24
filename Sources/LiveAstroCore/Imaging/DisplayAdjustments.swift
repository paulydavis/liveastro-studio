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
/// - backgroundDegree:    1 planar / 2 quad   — legacy polynomial DBE degree; retained for
///                                             old-settings decode compat, no longer driven by the UI
///                                             (the display path now uses the multiscale model)
/// - bgScale:             3.0 neutral         — multiscale DBE top scale (pixels)
/// - bgSmoothest:         0.5 neutral         — multiscale DBE smoothest octave weight
/// - denoiseStrength:    0 (off) … 1          — classic two-stage noise reduction (post-stretch)
public struct DisplayAdjustments: Equatable, Codable {
    public var blackPoint: Double
    public var midtoneStrength: Double
    public var saturation: Double
    public var backgroundExtraction: Bool
    public var backgroundDegree: Int
    public var bgScale: Double
    public var bgSmoothest: Double
    public var denoiseStrength: Double
    /// Rotate the DISPLAY to celestial north-up (3b). Display-only; needs a plate solve to take effect.
    public var northUp: Bool

    public init(blackPoint: Double = 0, midtoneStrength: Double = 0, saturation: Double = 1,
                backgroundExtraction: Bool = false, backgroundDegree: Int = 1,
                bgScale: Double = 3.0, bgSmoothest: Double = 0.5,
                denoiseStrength: Double = 0, northUp: Bool = false) {
        self.blackPoint = blackPoint
        self.midtoneStrength = midtoneStrength
        self.saturation = saturation
        self.backgroundExtraction = backgroundExtraction
        self.backgroundDegree = backgroundDegree
        self.bgScale = bgScale
        self.bgSmoothest = bgSmoothest
        self.denoiseStrength = denoiseStrength
        self.northUp = northUp
    }

    public static let neutral = DisplayAdjustments()

    /// The recommended starting look for the live display: neutral plus DBE on, so a
    /// light-pollution gradient is flattened out of the box. Display-only (master.fit
    /// is never touched) and one toggle to disable. Used as the fresh-install default
    /// and the Reset target — NOT as `neutral`, which stays the pure identity for
    /// tests/goldens/serialization.
    public static let liveDefault = DisplayAdjustments(backgroundExtraction: true)

    // Custom decode so a settings blob written before the DBE fields existed
    // still decodes (missing keys → defaults). Encode stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case blackPoint, midtoneStrength, saturation, backgroundExtraction, backgroundDegree, bgScale, bgSmoothest, denoiseStrength, northUp
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blackPoint = try c.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0
        midtoneStrength = try c.decodeIfPresent(Double.self, forKey: .midtoneStrength) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        backgroundExtraction = try c.decodeIfPresent(Bool.self, forKey: .backgroundExtraction) ?? false
        backgroundDegree = try c.decodeIfPresent(Int.self, forKey: .backgroundDegree) ?? 1
        bgScale = try c.decodeIfPresent(Double.self, forKey: .bgScale) ?? 3.0
        bgSmoothest = try c.decodeIfPresent(Double.self, forKey: .bgSmoothest) ?? 0.5
        denoiseStrength = try c.decodeIfPresent(Double.self, forKey: .denoiseStrength) ?? 0
        northUp = try c.decodeIfPresent(Bool.self, forKey: .northUp) ?? false
    }
}
