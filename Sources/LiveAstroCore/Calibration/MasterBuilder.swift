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

    public enum BuildError: Error, Equatable { case noFrames, noValidFrames }

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
    /// - The first successfully-read frame sets the reference dimensions; later frames of a
    ///   different size (or unreadable frames) are skipped and excluded from `contributingCount`.
    ///   Throws if no frames are readable.
    public static func combineDetailed(fitsURLs: [URL], kind: MasterKind,
                                       bias: AstroImage?) throws -> BuildResult {
        guard !fitsURLs.isEmpty else { throw BuildError.noFrames }

        var sum: [Double] = []
        var refW = 0, refH = 0, refC = 0
        var count = 0
        var offsetApplied = false

        for url in fitsURLs {
            guard let data = try? Data(contentsOf: url),
                  let img = try? FITSReader.read(data, normalizeRowOrder: true) else { continue }
            if count == 0 {
                refW = img.width; refH = img.height; refC = img.channels
                sum = [Double](repeating: 0, count: refW * refH * refC)
            } else if img.width != refW || img.height != refH || img.channels != refC {
                continue    // dimension mismatch → skip
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
