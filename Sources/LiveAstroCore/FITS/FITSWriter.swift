import Foundation

/// Minimal FITS writer: float32, mono or 3-channel. Used by tests and fakesiril.
public enum FITSWriter {

    public static func float32(width: Int, height: Int, channels: Int,
                               pixels: [Float], bottomUp: Bool = false) -> Data {
        precondition(pixels.count == width * height * channels)
        precondition(channels == 1 || channels == 3)

        func card(_ key: String, _ value: String) -> String {
            let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            return "\(k)= \(value)".padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        var cards = [card("SIMPLE", "T"), card("BITPIX", "-32"),
                     card("NAXIS", channels == 1 ? "2" : "3"),
                     card("NAXIS1", "\(width)"), card("NAXIS2", "\(height)")]
        if channels == 3 { cards.append(card("NAXIS3", "3")) }
        cards.append(card("ROWORDER", bottomUp ? "'BOTTOM-UP'" : "'TOP-DOWN'"))
        var s = cards.joined() + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        while s.count % 2880 != 0 { s += String(repeating: " ", count: 80) }
        var data = s.data(using: .ascii)!

        let plane = width * height
        for c in 0..<channels {
            for row in 0..<height {
                let srcRow = bottomUp ? (height - 1 - row) : row
                for col in 0..<width {
                    var be = pixels[c * plane + srcRow * width + col].bitPattern.bigEndian
                    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
                }
            }
        }
        while data.count % 2880 != 0 { data.append(0) }
        return data
    }
}
