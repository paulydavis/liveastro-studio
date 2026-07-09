import Foundation

public enum MasterKind { case dark, flat, bias }

/// Builds master calibration frames by mean-combining raw FITS frames.
/// Masters are canonical TOP-DOWN AstroImages (read with normalizeRowOrder: true),
/// so a bottom-up source is flipped in and all masters share one orientation.
public enum MasterBuilder {

    /// Divide-by-zero floor for flats: 1 ADU at 16-bit, normalized (FITSReader
    /// maps physical ÷ 65535 → [0,1], so 1.0 = full scale). Matches the Python
    /// prototype's clip(flat, 1.0) in ADU space.
    public static let flatFloor: Float = 1.0 / 65535

    public enum BuildError: Error, Equatable { case noFrames, noValidFrames }

    /// Mean-combine `fitsURLs` into a top-down master.
    /// - .flat: subtracts `bias` per-frame when provided, then clamps ≥ flatFloor
    ///   and normalizes to median 1.
    /// - The first successfully-read frame sets the reference dimensions; later
    ///   frames of a different size are skipped. Throws if no frames are readable.
    public static func combine(fitsURLs: [URL], kind: MasterKind,
                               bias: AstroImage?) throws -> AstroImage {
        guard !fitsURLs.isEmpty else { throw BuildError.noFrames }

        var sum: [Double] = []
        var refW = 0, refH = 0, refC = 0
        var count = 0

        for url in fitsURLs {
            guard let data = try? Data(contentsOf: url),
                  let img = try? FITSReader.read(data, normalizeRowOrder: true) else { continue }
            if count == 0 {
                refW = img.width; refH = img.height; refC = img.channels
                sum = [Double](repeating: 0, count: refW * refH * refC)
            } else if img.width != refW || img.height != refH || img.channels != refC {
                continue    // dimension mismatch → skip
            }
            // For flats, subtract bias per-frame when its dimensions match.
            if kind == .flat, let bias, bias.pixels.count == sum.count {
                for i in 0..<sum.count { sum[i] += Double(img.pixels[i]) - Double(bias.pixels[i]) }
            } else {
                for i in 0..<sum.count { sum[i] += Double(img.pixels[i]) }
            }
            count += 1
        }

        guard count > 0 else { throw BuildError.noValidFrames }

        var mean = sum.map { Float($0 / Double(count)) }

        if kind == .flat {
            for i in 0..<mean.count where mean[i] < flatFloor { mean[i] = flatFloor }
            let med = median(of: mean)
            let divisor = med < flatFloor ? flatFloor : med
            for i in 0..<mean.count { mean[i] /= divisor }
        }

        return AstroImage(width: refW, height: refH, channels: refC,
                          pixels: mean, sourceIsLinear: true)
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
        try data.write(to: url)
    }

    /// Load a pre-built master as a canonical top-down AstroImage.
    public static func load(_ url: URL) throws -> AstroImage {
        let data = try Data(contentsOf: url)
        let img = try FITSReader.read(data, normalizeRowOrder: true)
        return AstroImage(width: img.width, height: img.height, channels: img.channels,
                          pixels: img.pixels, sourceIsLinear: true)
    }
}
