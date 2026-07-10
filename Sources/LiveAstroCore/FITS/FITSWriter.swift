import Foundation

/// Minimal FITS writer: float32, mono or 3-channel. Used by tests and fakesiril.
public enum FITSWriter {

    public static func float32(width: Int, height: Int, channels: Int,
                               pixels: [Float], bottomUp: Bool = false,
                               metadata: SourceMetadata? = nil,
                               stackCount: Int? = nil,
                               totalExposureSeconds: Double? = nil) -> Data {
        precondition(pixels.count == width * height * channels)
        precondition(channels == 1 || channels == 3)

        // Fixed-format numeric/logical card: value right-justified, ending at column 30.
        func card(_ key: String, _ value: String) -> String {
            precondition(value.count <= 20, "FITS numeric card value too long: \(value)")
            let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            let valField = String(repeating: " ", count: max(0, 20 - value.count)) + value  // cols 11-30
            return "\(k)= \(valField)".padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        // Fixed-format string card: single-quoted, left-justified from column 11,
        // padded to at least 8 chars inside the quotes (FITS §4.2.1).
        func cardStr(_ key: String, _ value: String) -> String {
            let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            var inner = value.count < 8 ? value.padding(toLength: 8, withPad: " ", startingAt: 0) : value
            inner = String(inner.prefix(68))   // keep the card within 80 bytes
            return "\(k)= '\(inner)'".padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        // Format doubles without trailing noise: integer-valued → no decimals, else full.
        func trim(_ d: Double) -> String {
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        }
        var cards = [card("SIMPLE", "T"), card("BITPIX", "-32"),
                     card("NAXIS", channels == 1 ? "2" : "3"),
                     card("NAXIS1", "\(width)"), card("NAXIS2", "\(height)")]
        if channels == 3 { cards.append(card("NAXIS3", "3")) }
        cards.append(cardStr("ROWORDER", bottomUp ? "BOTTOM-UP" : "TOP-DOWN"))

        // Emit propagated astronomical metadata
        if let m = metadata {
            if let v = m.object { cards.append(cardStr("OBJECT", v)) }
            if let v = m.ra { cards.append(card("RA", trim(v))) }
            if let v = m.dec { cards.append(card("DEC", trim(v))) }
            if let v = m.focalLengthMM { cards.append(card("FOCALLEN", trim(v))) }
            if let v = m.pixelSizeUM { cards.append(card("XPIXSZ", trim(v))); cards.append(card("YPIXSZ", trim(v))) }
            if let v = m.instrument { cards.append(cardStr("INSTRUME", v)) }
            if let v = m.telescope { cards.append(cardStr("TELESCOP", v)) }
            if let v = m.filter { cards.append(cardStr("FILTER", v)) }
            if let v = m.exposureSeconds { cards.append(card("EXPTIME", trim(v))) }
            if let v = m.dateObs { cards.append(cardStr("DATE-OBS", v)) }
            if let v = m.gain { cards.append(card("GAIN", trim(v))) }
            if let v = m.ccdTempC { cards.append(card("CCD-TEMP", trim(v))) }
            if let v = m.siteLat { cards.append(card("SITELAT", trim(v))) }
            if let v = m.siteLon { cards.append(card("SITELONG", trim(v))) }
        }
        if let n = stackCount { cards.append(card("STACKCNT", "\(n)")) }
        if let t = totalExposureSeconds { cards.append(card("TOTALEXP", trim(t))) }
        cards.append("HISTORY Stacked by LiveAstro Studio".padding(toLength: 80, withPad: " ", startingAt: 0))
        // Note: BAYERPAT intentionally omitted — the RGB master is already debayered.

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
