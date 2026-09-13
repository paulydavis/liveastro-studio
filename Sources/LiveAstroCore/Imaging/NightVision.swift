import Foundation

/// Parameters for the red night-vision display tint.
///
/// Night vision strips green and blue out of the display's gamma table so only
/// red light leaves the panel, preserving dark adaptation while you check the
/// Mac at the telescope. The brightness `level` scales the red channel's output
/// ceiling (lower = dimmer). This value type holds only the pure level→gamma
/// mapping and its validation; writing the gamma table to a physical display
/// (CoreGraphics, which cannot run in CI) lives in the app layer.
public struct NightVision: Equatable {
    /// Brightness percent, always within ``minLevel``...``maxLevel``.
    public let level: Int

    public static let defaultLevel = 65
    public static let minLevel = 1
    public static let maxLevel = 100

    /// Clamp an arbitrary integer into the valid brightness range.
    public static func clamp(_ level: Int) -> Int {
        min(maxLevel, max(minLevel, level))
    }

    public init(level: Int = NightVision.defaultLevel) {
        self.level = NightVision.clamp(level)
    }

    /// The red channel's output ceiling (0...1] for `CGSetDisplayTransferByFormula`.
    /// Green and blue ceilings are always 0 — those channels are pinned off.
    public var redMax: Float { Float(level) / 100.0 }
}
