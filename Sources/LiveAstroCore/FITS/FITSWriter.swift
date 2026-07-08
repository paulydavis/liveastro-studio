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
        // Pad the header with spaces to a 2880-byte block boundary (FITS §3.1).
        // Exact-remainder form: terminates for ANY length, unlike stepping in
        // 80-byte chunks, which would spin forever if a card ever weren't 80 bytes.
        let headerPad = (2880 - s.count % 2880) % 2880
        s += String(repeating: " ", count: headerPad)
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
        // Zero-pad the data section to a block boundary, in one append.
        let dataPad = (2880 - data.count % 2880) % 2880
        data.append(Data(repeating: 0, count: dataPad))
        return data
    }
}
