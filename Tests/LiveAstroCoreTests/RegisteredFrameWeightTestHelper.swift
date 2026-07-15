import Foundation
@testable import LiveAstroCore

extension StackEngine {
    /// Test helper mirroring the production commit-path weight computation (P1-4):
    /// the frame weight uses σ·(APPLIED scale), where the applied scale is reg.scale only when a
    /// leveling pair exists AND passes GradientLeveler.scalingApplies; otherwise the scale is
    /// suppressed to 1.0 and the weight is σ-only. Returns (weight, effectiveScale) so callers can
    /// pass both to commit() exactly as BatchImporter does.
    func committedWeightAndScale(
        reg: RegisteredFrame,
        leveling: (sub: BackgroundExtraction.BackgroundModel, ref: BackgroundExtraction.BackgroundModel)?,
        channels: Int
    ) -> (weight: Float, scale: Float) {
        let effectiveScale: Float
        if let lv = leveling,
           GradientLeveler.scalingApplies(subModel: lv.sub, refModel: lv.ref, channels: channels) {
            effectiveScale = reg.scale
        } else {
            effectiveScale = 1.0
        }
        let weight = frameWeight(stars: reg.stars, sigma: reg.sigma * effectiveScale)
        return (weight, effectiveScale)
    }
}
