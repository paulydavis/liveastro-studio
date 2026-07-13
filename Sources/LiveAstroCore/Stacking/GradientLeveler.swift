// Sources/LiveAstroCore/Stacking/GradientLeveler.swift
import Foundation

/// Reference-matched per-sub background leveling (spec: gradient leveling).
/// For each channel where BOTH the sub and reference models have coefficients,
/// subtracts the difference surface (coeff_sub − coeff_ref) and clamps to [0,1].
/// A channel with either coeff missing is passthrough. Identical models return
/// the frame byte-identical. Deterministic; parallel over row bands.
public enum GradientLeveler {
    public static func apply(_ image: AstroImage,
                             subModel: BackgroundExtraction.BackgroundModel,
                             refModel: BackgroundExtraction.BackgroundModel,
                             minRows: Int = 64) -> AstroImage {
        let w = image.width, h = image.height, chans = image.channels, plane = w * h
        let deg = subModel.degree
        var out = image.pixels
        out.withUnsafeMutableBufferPointer { buf in
            for c in 0..<chans {
                guard c < subModel.coeffPerChannel.count, c < refModel.coeffPerChannel.count,
                      let cs = subModel.coeffPerChannel[c], let cr = refModel.coeffPerChannel[c] else { continue }
                let diff = zip(cs, cr).map { $0 - $1 }
                if diff.allSatisfy({ $0 == 0 }) { continue }        // identical → passthrough (byte-identical)
                let surface = BackgroundExtraction.BackgroundModel.evaluate(coeff: diff, degree: deg, width: w, height: h)
                let base = c * plane
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let i = base + y * w + x
                            buf[i] = min(max(buf[i] - surface[y * w + x], 0), 1)
                        }
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: chans, pixels: out, sourceIsLinear: image.sourceIsLinear)
    }
}
