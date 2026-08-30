import Foundation

/// Reproduces a REGISTERED sub's calibrated, display-RGB, UN-warped frame for the
/// `GlobalRefiner` — exactly what the online `StackEngine` fed to `Warp.apply`.
/// **Digest-only verification**: `expectedContentDigest` is the content-SHA256 captured at
/// online-pass time (stat fields zeroed — see `SubRegistration.contentDigest`); a full
/// stat-inclusive `FileIdentity` check would spuriously fail on re-read (a Google-Drive
/// mirror / SMB re-sync recreates a byte-identical file with a new inode/mtime — the
/// re-stack P1b lesson). Tests inject a stub; `ProductionFrameLoader` below is the real impl.
public protocol FrameLoader {
    func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage
}

/// Production `FrameLoader` (Task 6 I2): applies the session's ACTUALLY-APPLIED calibrator
/// (the caller must pass `SessionPipeline.effectiveCalibrator`, NOT a freshly-rebuilt one —
/// a rebuilt calibrator resolves to nil for an empty-folder live start), then the shared
/// `DisplayRGB.make` with the SAME `DemosaicMethod` the engine was built with — one
/// implementation, no drift between the online and refine domains a warped/leveled sub is
/// compared in.
public struct ProductionFrameLoader: FrameLoader {
    private let calibrator: Calibrator?
    private let demosaic: DemosaicMethod

    public init(calibrator: Calibrator?, demosaic: DemosaicMethod) {
        self.calibrator = calibrator
        self.demosaic = demosaic
    }

    public func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
        let raw = try FolderFrameSource.loadRawFrame(url: url, expectedDigest: expectedContentDigest)
        let calibrated = calibrator?.apply(raw) ?? raw
        return DisplayRGB.make(calibrated, demosaic: demosaic)
    }
}

/// Bounded, cancellable, background live-rejection pass (spec §3, GlobalCombine): reproduces
/// each surviving sub from the Task 5 registration cache (load calibrated frame → warp →
/// level), computes a robust per-pixel center over a RAM sample, then a weighted clipped mean
/// over ALL survivors — removing satellite trails / cosmic rays the online winsorized engine
/// can't (its per-pixel state only ever sees ONE frame at a time).
public final class GlobalRefiner {
    /// Aborts the CURRENT `refine` pass (cancel or past-deadline) — always unwinds to `nil`
    /// (the online master is kept; never a partial publish).
    private struct AbortPass: Error {}

    private let loader: FrameLoader
    private let onLog: (String) -> Void

    /// Concrete NSLock-guarded cancellation flag (C3/step 7) — NOT `Task.isCancelled`, since a
    /// pass runs on a caller-owned `DispatchQueue`, not a `Task`. Each `refine` call stamps a
    /// fresh, monotonically-incrementing `passId`; `cancel()` only ever records WHICHEVER id is
    /// current at the moment it's called. Because a passId is never reused and `cancelledPassId`
    /// is never reset, a `cancel()` that lands after its target pass already finished (and
    /// before the NEXT pass starts) leaves a stale id on record that can never equal a later
    /// pass's fresh id — so a late `cancel()` can't kill the next pass.
    private let passLock = NSLock()
    private var currentPassId = 0
    private var cancelledPassId: Int?

    /// Test-only observability seam (P2-2 / brief step 1): the materialized RAM-sample size,
    /// AFTER the odd-invariant adjustment, from the most recently STARTED `refine` call.
    /// `GlobalCombine.robustCenter` is a pure static func with no spy seam, so a capped pass's
    /// selected-frame-failure → even → drop-last behavior is asserted observably through this
    /// rather than inferred indirectly from output pixels.
    private(set) var lastMaterializedSampleCount: Int?

    public init(loader: FrameLoader, onLog: @escaping (String) -> Void) {
        self.loader = loader
        self.onLog = onLog
    }

    /// Marks the pass CURRENTLY in flight (or about to start) as cancelled. See the `passLock`
    /// doc above for why a late call can't cancel a future pass.
    public func cancel() {
        passLock.withLock { cancelledPassId = currentPassId }
    }

    /// - Parameters:
    ///   - survivors: already-snapshotted (M3, Task 8) — `refine` does not re-read the pipeline.
    ///   - currentGeneration: the generation to filter to, by EXPLICIT equality (never majority —
    ///     after a reseed, old-generation frames could outnumber the new ones).
    ///   - kappa: `GlobalCombine.clippedWeightedMean` clip multiple.
    ///   - minSubs: quorum floor, both for the materialized RAM sample and the final survivor
    ///     count (same value as the Task 11 online gate).
    ///   - maxSampleBytes: RAM budget for the robust-center sample; `maxSampleFrames` is derived
    ///     from the first successfully-loaded frame's actual size. `maxSampleFrames < 11` is a
    ///     HARD floor — the pass logs and returns nil (online master kept) rather than computing
    ///     an under-powered robust center.
    ///   - deadline / isCancelled: checked BETWEEN every per-sub load+warp (the minutes-long
    ///     part); the per-pixel CPU reduction inside `robustCenter`/`clippedWeightedMean` (~
    ///     seconds at 26MP) is not interruptible mid-loop — acceptable, the between-sub work
    ///     dominates the bound.
    public func refine(survivors: [SubRegistration], currentGeneration: Int, kappa: Float,
                       minSubs: Int, maxSampleBytes: Int, deadline: DispatchTime,
                       isCancelled: @escaping () -> Bool) -> RefineResult? {
        let thisPassId: Int = passLock.withLock {
            currentPassId += 1
            return currentPassId
        }
        func stopRequested() -> Bool {
            if isCancelled() { return true }
            return passLock.withLock { cancelledPassId == thisPassId }
        }
        // A load/digest failure RETURNS nil (recoverable — caller does skippedIds.insert).
        // Cancel/deadline THROWS AbortPass — unwinds the whole `refine` body below.
        func loadWarp(_ reg: SubRegistration) throws -> (image: AstroImage, mask: [Float])? {
            if stopRequested() || DispatchTime.now() >= deadline { throw AbortPass() }
            let rgb: AstroImage
            do {
                rgb = try loader.loadRegisteredInput(url: reg.relayURL, expectedContentDigest: reg.contentDigest)
            } catch {
                return nil
            }
            let (warped, mask) = Warp.apply(rgb, transform: reg.transform.liftedToFullResolution())
            guard let leveling = reg.leveling else { return (warped, mask) }
            let leveled = GradientLeveler.apply(warped, subModel: leveling.sub, refModel: leveling.ref,
                                                scale: reg.effectiveScale)
            return (leveled, mask)
        }

        // Skip tracking by subIndex for the WHOLE pass — never a scalar counter (a scalar could
        // double-count the same sub across the dim-probe / sample-build / output-stream phases).
        var skippedIds = Set<Int>()
        var loaded = [Int: (image: AstroImage, mask: [Float])]()
        var aborted = false

        do {
            // 1. Filter to the current generation by EXPLICIT equality — never majority.
            let inGen = survivors.filter { $0.stackGeneration == currentGeneration }

            // 3. Sizing: walk inGen in order; the FIRST reg whose loadWarp succeeds gives dims.
            var sampleFrameBytes: Int?
            for reg in inGen {
                if let result = try loadWarp(reg) {
                    loaded[reg.subIndex] = result
                    sampleFrameBytes = result.image.pixels.count * 4 + result.mask.count * 4
                    break
                }
                skippedIds.insert(reg.subIndex)
            }
            guard let sampleFrameBytes, sampleFrameBytes > 0 else { return nil }  // none loaded → quorum fails
            let maxSampleFrames = max(1, maxSampleBytes / sampleFrameBytes)
            guard maxSampleFrames >= 11 else {
                onLog("live rejection off: insufficient sample budget (\(maxSampleFrames) < 11 frames)")
                return nil
            }

            // 4. Build the RAM sample (dimension-probe frame enters only if its index ∈ idxs).
            let idxs = SubRegistration.sampleIndices(count: inGen.count, maxSampleFrames: maxSampleFrames)
            var sample: [(image: AstroImage, mask: [Float])] = []
            for i in idxs {
                let reg = inGen[i]
                if let cached = loaded[reg.subIndex] {
                    sample.append(cached)
                } else if let result = try loadWarp(reg) {
                    loaded[reg.subIndex] = result
                    sample.append(result)
                } else {
                    skippedIds.insert(reg.subIndex)
                }
            }
            // Odd-invariant (P2-4): selected-frame load failures can leave the materialized
            // sample EVEN even though `idxs.count` was already odd (sampleIndices' own
            // reduction) — drop the last for a true per-pixel middle median, deterministically.
            if !sample.isEmpty, sample.count % 2 == 0 { sample.removeLast() }
            guard sample.count >= minSubs else { return nil }   // fail closed
            lastMaterializedSampleCount = sample.count

            guard let centerResult = GlobalCombine.robustCenter(sample: sample) else { return nil }

            // 5. Output — reuse under budget, stream when capped.
            let combined: (image: AstroImage, coverage: [Float])?
            if inGen.count <= maxSampleFrames {
                // Under budget: idxs == all indices, so `loaded` already holds every survivor
                // that loaded successfully. Iterate in inGen ORDER (not loaded.values — dict
                // iteration is nondeterministic and Float summation order is byte-significant).
                let framesArr: [(image: AstroImage, mask: [Float], weight: Float)] = inGen.compactMap { reg in
                    loaded[reg.subIndex].map { (image: $0.image, mask: $0.mask, weight: reg.weight) }
                }
                combined = GlobalCombine.clippedWeightedMean(
                    frames: { AnyIterator(framesArr.makeIterator()) },
                    center: centerResult.center, scale: centerResult.scale, kappa: kappa)
            } else {
                // Capped: stream fresh from the loader for subs not already cached from
                // sizing/sample-build. Two hazards (P2-3): (a) a per-sub load failure must NOT
                // return nil from the iterator (nil == "stream done", would truncate the
                // combine) — skip + advance instead; (b) an AbortPass sets the out-of-band
                // `aborted` flag and ends iteration; checked AFTER clippedWeightedMean below so
                // a cancel mid-stream can never publish a partial master as if it finished.
                var streamIdx = 0
                combined = GlobalCombine.clippedWeightedMean(
                    frames: {
                        AnyIterator<(image: AstroImage, mask: [Float], weight: Float)> {
                            while streamIdx < inGen.count {
                                let reg = inGen[streamIdx]
                                streamIdx += 1
                                if let cached = loaded[reg.subIndex] {
                                    return (cached.image, cached.mask, reg.weight)
                                }
                                do {
                                    if let result = try loadWarp(reg) {
                                        loaded[reg.subIndex] = result
                                        return (result.image, result.mask, reg.weight)
                                    }
                                    skippedIds.insert(reg.subIndex)   // recoverable — advance
                                } catch {
                                    aborted = true
                                    return nil                        // ends iteration only
                                }
                            }
                            return nil
                        }
                    },
                    center: centerResult.center, scale: centerResult.scale, kappa: kappa)
            }
            if aborted { return nil }
            guard let combined else { return nil }

            // 6. Quorum over the WHOLE generation set (the frames that actually contributed —
            // what Task 10's STACKCNT/TOTALEXP use, not the pre-skip count).
            let contributing = inGen.count - skippedIds.count
            guard contributing >= minSubs else { return nil }
            return RefineResult(image: combined.image, coverage: combined.coverage,
                                survivorCount: contributing, skipped: skippedIds.count)
        } catch {
            // Any AbortPass (cancel/deadline) thrown from the sizing or sample-build phases
            // unwinds here — never a partial publish; the caller keeps the last online master.
            return nil
        }
    }
}

public struct RefineResult {
    public let image: AstroImage
    public let coverage: [Float]
    public let survivorCount: Int
    public let skipped: Int

    public init(image: AstroImage, coverage: [Float], survivorCount: Int, skipped: Int) {
        self.image = image
        self.coverage = coverage
        self.survivorCount = survivorCount
        self.skipped = skipped
    }
}
