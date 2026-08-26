import Foundation

public enum MasterKind: String, Codable { case dark, flat, bias }

/// Builds master calibration frames by mean-combining raw FITS frames.
/// Masters are canonical TOP-DOWN AstroImages (read with normalizeRowOrder: true),
/// so a bottom-up source is flipped in and all masters share one orientation.
public enum MasterBuilder {

    /// Divide-by-zero floor for flats: 1 ADU at 16-bit, normalized (FITSReader
    /// maps physical ÷ 65535 → [0,1], so 1.0 = full scale). Matches the Python
    /// prototype's clip(flat, 1.0) in ADU space.
    public static let flatFloor: Float = 1.0 / 65535

    public enum BuildError: Error, Equatable { case noFrames, noValidFrames, frameTooLarge }

    /// Upper bound on total elements (width·height·channels) of a master's accumulation buffer.
    /// 500 M Doubles ≈ 4 GB — comfortably above any real sensor (a 150 MP RGB frame is ~450 M
    /// elements) but a hard stop against a hostile/corrupt FITS header (e.g. NAXIS 1e6×1e6) that
    /// would otherwise demand tens of terabytes.
    public static let maxPixelElements = 500_000_000

    /// A built master plus honest accounting of what actually went into it: how many frames
    /// contributed (readable + matching dimensions — NOT the input count, which may include skipped
    /// files) and, for flats, whether the offset was truly subtracted (it is silently skipped when
    /// the offset's dimensions don't match, so callers must not claim "offset subtracted" blindly).
    public struct BuildResult {
        public let image: AstroImage
        public let contributingCount: Int
        public let offsetApplied: Bool
    }

    /// Mean-combine `fitsURLs` into a top-down master. Facade returning just the image; use
    /// `combineDetailed` when the contributing count or offset-applied flag is needed.
    public static func combine(fitsURLs: [URL], kind: MasterKind,
                               bias: AstroImage?) throws -> AstroImage {
        try combineDetailed(fitsURLs: fitsURLs, kind: kind, bias: bias).image
    }

    /// Mean-combine with full accounting (see `BuildResult`).
    /// - .flat: subtracts `bias` per-frame when its dimensions match, then clamps ≥ flatFloor
    ///   and normalizes to median 1. The `bias` input may be a bias master or a matched dark-flat
    ///   master; both occupy the same flat-offset role. A dimension-mismatched offset is skipped
    ///   and reported via `offsetApplied == false`.
    /// - `expected`: when given, ONLY frames of exactly these dimensions contribute (the reference is
    ///   fixed up front). Session calibration passes the light's target size so a stray wrong-size
    ///   frame that happens to sort first can't hijack the reference and discard the valid frames.
    ///   When nil, the first successfully-read frame sets the reference (later mismatches skipped).
    /// - Unreadable/mismatched frames are excluded from `contributingCount`. Throws if none contribute.
    public static func combineDetailed(fitsURLs: [URL], kind: MasterKind, bias: AstroImage?,
                                       expected: (width: Int, height: Int, channels: Int)? = nil) throws -> BuildResult {
        guard !fitsURLs.isEmpty else { throw BuildError.noFrames }

        var sum: [Double] = []
        var refW = 0, refH = 0, refC = 0
        var count = 0
        var offsetApplied = false
        var haveRef = false
        if let e = expected {
            guard e.width > 0, e.height > 0, e.channels > 0 else { throw BuildError.noValidFrames }
            refW = e.width; refH = e.height; refC = e.channels; haveRef = true
            // NOTE: do NOT allocate here — a hostile `expected` size that no frame matches must not
            // force a giant buffer. Allocation happens (bounded) only when a real frame matches.
        }

        for url in fitsURLs {
            guard let data = try? Data(contentsOf: url),
                  let img = try? FITSReader.read(data, normalizeRowOrder: true) else { continue }
            if !haveRef {
                refW = img.width; refH = img.height; refC = img.channels; haveRef = true
            } else if img.width != refW || img.height != refH || img.channels != refC {
                continue    // doesn't match the reference (expected, or first-readable) → skip
            }
            // Allocate the accumulator on the FIRST contributing frame, bounded by a pixel ceiling so
            // a corrupt/hostile dimension can't demand a multi-terabyte buffer.
            if sum.isEmpty {
                let elements = refW * refH * refC
                guard elements > 0, elements <= maxPixelElements else { throw BuildError.frameTooLarge }
                sum = [Double](repeating: 0, count: elements)
            }
            // For flats, subtract the selected bias/dark-flat per-frame when its
            // dimensions match; otherwise fall through WITHOUT subtracting (recorded below).
            if kind == .flat, let bias,
               bias.width == refW && bias.height == refH && bias.channels == refC {
                for i in 0..<sum.count { sum[i] += Double(img.pixels[i]) - Double(bias.pixels[i]) }
                offsetApplied = true
            } else {
                for i in 0..<sum.count { sum[i] += Double(img.pixels[i]) }
            }
            count += 1
        }

        guard count > 0 else { throw BuildError.noValidFrames }

        let mean = sum.map { Float($0 / Double(count)) }
        let raw = AstroImage(width: refW, height: refH, channels: refC,
                             pixels: mean, sourceIsLinear: true)
        let image = (kind == .flat) ? normalizedFlat(raw) : raw
        return BuildResult(image: image, contributingCount: count, offsetApplied: offsetApplied)
    }

    /// Clamp a flat to ≥ flatFloor and normalize it to median 1 (a dimensionless
    /// multiplier). Idempotent: an already-normalized flat (median 1) is unchanged.
    /// Applied to every flat — built in-app or loaded from an external file — so a
    /// non-normalized external master flat still divides correctly.
    public static func normalizedFlat(_ image: AstroImage) -> AstroImage {
        var pixels = image.pixels
        for i in 0..<pixels.count where pixels[i] < flatFloor { pixels[i] = flatFloor }
        let med = median(of: pixels)
        for i in 0..<pixels.count { pixels[i] /= med }
        return AstroImage(width: image.width, height: image.height, channels: image.channels,
                          pixels: pixels, sourceIsLinear: true)
    }

    /// Exact median via full sort of a copy (one-time build; correctness over speed).
    private static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var v = values; v.sort()
        let mid = v.count / 2
        return v.count % 2 == 0 ? (v[mid - 1] + v[mid]) / 2 : v[mid]
    }

    /// Save a master as Float32 top-down FITS (ROWORDER = TOP-DOWN).
    public static func save(_ master: AstroImage, to url: URL) throws {
        let data = FITSWriter.float32(width: master.width, height: master.height,
                                      channels: master.channels, pixels: master.pixels,
                                      bottomUp: false)
        try data.write(to: url, options: .atomic)
    }

    /// Load a pre-built master as a canonical top-down AstroImage.
    public static func load(_ url: URL) throws -> AstroImage {
        let data = try Data(contentsOf: url)
        let img = try FITSReader.readLinear(data, normalizeRowOrder: true)
        // Master frames are always linear calibration data (dark/flat/bias-or-dark-flat),
        // never raw Bayer.
        return AstroImage(width: img.width, height: img.height, channels: img.channels,
                          pixels: img.pixels, sourceIsLinear: true)
    }
}
