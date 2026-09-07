import CoreGraphics
import Foundation

/// Luminance histogram of a RENDERED display image.
///
/// Deliberately computed from the rendered 8-bit CGImage rather than the linear stack: it is
/// meant to answer "what is the stretch doing with the range I can actually see" — whether
/// shadows are being crushed, whether highlights are clipping — which is the question the black
/// point and stretch controls exist to answer. A linear-domain histogram would bunch every
/// pixel into the first bin or two (a real M51 master sits around 0.0095 with a MADN of 0.00007)
/// and show the operator nothing.
public enum DisplayHistogram {
    public static let defaultBins = 128

    /// Counts per luminance bin, low to high. Empty if the image cannot be read.
    public static func of(_ image: CGImage, bins: Int = defaultBins) -> [Int] {
        guard bins > 1, let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return [] }
        let length = CFDataGetLength(data)
        let bpp = max(1, image.bitsPerPixel / 8)
        let bpr = image.bytesPerRow
        let w = image.width, h = image.height
        guard w > 0, h > 0, bpr > 0 else { return [] }

        var counts = [Int](repeating: 0, count: bins)
        let scale = Double(bins - 1) / 255.0
        // Stride the rows: a preview proxy is ~1-2 MP and the shape of the distribution is
        // unchanged by sampling, so this stays cheap enough to run on every draft render.
        let rowStep = max(1, h / 512)
        let colStep = max(1, w / 512)
        for y in stride(from: 0, to: h, by: rowStep) {
            let row = y * bpr
            for x in stride(from: 0, to: w, by: colStep) {
                let i = row + x * bpp
                guard i < length else { continue }
                // The render can be GRAYSCALE (1 byte/pixel) or colour. Reading i+1 and i+2
                // unconditionally treats the NEXT TWO PIXELS as green and blue on a grayscale
                // image, which smears luminance across region boundaries — it produced phantom
                // bins exactly at the light/dark edge of a two-tone test frame.
                let y709: Double
                if bpp >= 3 {
                    guard i + 2 < length else { continue }
                    y709 = 0.2126 * Double(ptr[i]) + 0.7152 * Double(ptr[i + 1])
                         + 0.0722 * Double(ptr[i + 2])
                } else {
                    y709 = Double(ptr[i])
                }
                counts[min(bins - 1, max(0, Int(y709 * scale)))] += 1
            }
        }
        return counts
    }
}
