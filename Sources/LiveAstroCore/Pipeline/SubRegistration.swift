import Foundation

/// Everything the GlobalRefiner needs to re-produce an accepted sub WITHOUT re-registering it.
/// Captured by the online pass; keyed by `subIndex` (unique per sub; `contentDigest` is for byte
/// re-verification only, never a key). The reference frame's record is
/// transform=identity, effectiveScale=1, weight=1, leveling=nil, referenceIdentity=its own identity.
public struct SubRegistration {
    public let subIndex: Int                             // per-sub monotonic ID (= processedCount == SubFrameRecord.index); THE key
    public let contentDigest: String?                    // for byte re-verification only; NOT a key (byte-identical subs are distinct)
    public let relayURL: URL
    public let stackGeneration: Int
    public let referenceIdentity: FileIdentity?
    public let transform: SimilarityTransform            // half-res; lift in warp
    public let effectiveScale: Float                     // the APPLIED scale (1.0 when unscaled)
    public let weight: Float                             // frameWeight(stars, sigma·effectiveScale)
    public let leveling: (sub: BackgroundExtraction.BackgroundModel,
                          ref: BackgroundExtraction.BackgroundModel)?
    public init(subIndex: Int, contentDigest: String?, relayURL: URL, stackGeneration: Int,
                referenceIdentity: FileIdentity?, transform: SimilarityTransform, effectiveScale: Float,
                weight: Float, leveling: (sub: BackgroundExtraction.BackgroundModel, ref: BackgroundExtraction.BackgroundModel)?) {
        self.subIndex = subIndex; self.contentDigest = contentDigest; self.relayURL = relayURL
        self.stackGeneration = stackGeneration; self.referenceIdentity = referenceIdentity
        self.transform = transform; self.effectiveScale = effectiveScale; self.weight = weight; self.leveling = leveling
    }

    /// Deterministic sample selection for the robust-center estimate (spec §3). All indices when
    /// `count <= maxSampleFrames`; otherwise EXACTLY k evenly-spaced indices where k = `maxSampleFrames`
    /// reduced to odd (true middle element for the per-pixel median). RAM is the HARD bound: the result
    /// NEVER exceeds `maxSampleFrames`. There is no `minSampleFrames` floor that could override the cap;
    /// `maxSampleFrames >= 11` is checked hard on the first refine (Task 6, dims known then) and
    /// advisory-logged at session start (Task 11). No RNG.
    public static func sampleIndices(count: Int, maxSampleFrames: Int) -> [Int] {
        guard count > 0, maxSampleFrames > 0 else { return [] }        // airtight: cap <= 0 → empty (never [0])
        if count <= maxSampleFrames { return Array(0..<count) }        // shallow: use all (incl. N=5)
        var k = maxSampleFrames
        if k % 2 == 0 { k -= 1 }                                       // odd — a true per-pixel median
        if k <= 1 { return [0] }
        return (0..<k).map { $0 * (count - 1) / (k - 1) }             // exactly k, ascending, distinct, <= count-1
    }
}
