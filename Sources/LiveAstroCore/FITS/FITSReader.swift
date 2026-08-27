import Foundation

public enum FITSReader {

    // FITS format constants (FITS Standard 4.0 §3.1): headers are a sequence of
    // 2880-byte blocks, each holding 36 card images of 80 ASCII characters —
    // sizes inherited from 80-column punch cards and 1970s tape blocking.
    public static let blockSize = 2880
    static let cardSize = 80
    static let cardsPerBlock = blockSize / cardSize   // 36

    public static func readHeader(_ data: Data) throws -> FITSHeader {
        let data = data.startIndex == 0 ? data : Data(data)
        if data.count < 6 {
            throw FITSError.truncatedHeader
        }
        guard String(data: data.prefix(6), encoding: .ascii) == "SIMPLE" else {
            throw FITSError.notFITS
        }
        var cards: [String: String] = [:]
        var headerBytes: Int?
        var block = 0
        while headerBytes == nil {
            let base = block * Self.blockSize
            guard base + Self.blockSize <= data.count else { throw FITSError.truncatedHeader }
            for i in 0..<Self.cardsPerBlock {
                let start = base + i * Self.cardSize
                guard let card = String(data: data.subdata(in: start..<(start + Self.cardSize)), encoding: .ascii) else {
                    throw FITSError.malformedHeader("non-ASCII card at byte \(start)")
                }
                let key = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
                if key == "END" { headerBytes = base + Self.blockSize; break }
                let idx8 = card.index(card.startIndex, offsetBy: 8)
                if card[idx8...].hasPrefix("= ") {
                    let raw = String(card[card.index(idx8, offsetBy: 2)...])
                    cards[key] = Self.parseCardValue(raw)
                }
            }
            block += 1
        }

        func intValue(_ key: String) throws -> Int {
            guard let s = cards[key], let v = Int(s) else { throw FITSError.malformedHeader("missing/bad \(key)") }
            return v
        }

        let bitpix = try intValue("BITPIX")
        guard [8, 16, 32, -32, -64].contains(bitpix) else { throw FITSError.unsupported("BITPIX \(bitpix)") }
        let naxis = try intValue("NAXIS")
        guard naxis == 2 || naxis == 3 else { throw FITSError.unsupported("NAXIS \(naxis)") }
        var dims = [try intValue("NAXIS1"), try intValue("NAXIS2")]
        if naxis == 3 {
            let c = try intValue("NAXIS3")
            guard c == 3 else { throw FITSError.unsupported("NAXIS3 \(c) (expected 3)") }
            dims.append(c)
        }
        guard dims[0] > 0, dims[1] > 0 else { throw FITSError.malformedHeader("non-positive dimensions") }
        // Sanity: reject implausible axes and any pixel-count/byte-size that would
        // overflow Int (dataBytes/minimumFileSize compute dims.reduce(1,*) * |BITPIX|/8
        // with trapping arithmetic — validate here with checked multiplies instead).
        guard dims.allSatisfy({ $0 <= 100_000 }) else {
            throw FITSError.malformedHeader("implausible dimensions")
        }
        var totalBytes = abs(bitpix) / 8
        for d in dims {
            let (product, overflow) = totalBytes.multipliedReportingOverflow(by: d)
            guard !overflow else { throw FITSError.malformedHeader("implausible dimensions") }
            totalBytes = product
        }
        let bscale = try doubleValue("BSCALE", default: 1, cards: cards)
        let bzero = try doubleValue("BZERO", default: 0, cards: cards)
        let bottomUp = (cards["ROWORDER"] ?? "BOTTOM-UP").uppercased() != "TOP-DOWN"
        // The checks above already enforce the validating init's constraints, so this never fails;
        // the guard is the belt to the init's braces (a validating init is the single source of truth).
        guard let header = FITSHeader(bitpix: bitpix, dims: dims, bscale: bscale, bzero: bzero,
                                      bottomUp: bottomUp, headerBytes: headerBytes!, keywords: cards) else {
            throw FITSError.malformedHeader("invalid header values")
        }
        return header
    }

    /// `normalizeRowOrder`: true (default) flips bottom-up files to top-down for
    /// display consumers; false returns pixels exactly as stored — required by CFA
    /// consumers (debayering a flipped mosaic shifts the Bayer phase and swaps R/B).

    /// Parse a FITS card value field (the bytes after "= "), per the standard:
    /// a '/' starts a comment only OUTSIDE quoted strings, and a quote inside
    /// a string is escaped by doubling ('O''HARA' means O'HARA).
    static func parseCardValue(_ raw: String) -> String {
        let trimmed = raw.drop(while: { $0 == " " })
        if trimmed.first == "'" {
            var value = ""
            var i = trimmed.index(after: trimmed.startIndex)
            while i < trimmed.endIndex {
                let ch = trimmed[i]
                if ch == "'" {
                    let next = trimmed.index(after: i)
                    if next < trimmed.endIndex, trimmed[next] == "'" {
                        value.append("'")          // escaped quote
                        i = trimmed.index(after: next)
                        continue
                    }
                    break                          // closing quote
                }
                value.append(ch)
                i = trimmed.index(after: i)
            }
            // FITS pads string values with trailing spaces inside the quotes
            return value.trimmingCharacters(in: .whitespaces)
        }
        // Unquoted: strip comment at the first '/', then trim
        let beforeComment = trimmed.prefix(while: { $0 != "/" })
        return beforeComment.trimmingCharacters(in: .whitespaces)
    }

    /// Test-only counter of full pixel DECODES (every `read`/`readLinear`), letting a test prove a
    /// frame was skipped BEFORE its pixels were decoded rather than decoded-then-discarded. INTERNAL
    /// (not public API) and lock-guarded so concurrent reads / parallel tests can't race it.
    private static let decodeCountLock = NSLock()
    private static var _decodeCount = 0
    static var decodeCountForTesting: Int {
        get { decodeCountLock.withLock { _decodeCount } }
        set { decodeCountLock.withLock { _decodeCount = newValue } }
    }
    private static func noteDecodeForTesting() { decodeCountLock.withLock { _decodeCount += 1 } }

    public static func read(_ data: Data, normalizeRowOrder: Bool = true) throws -> FITSImage {
        try read(data, normalizeRowOrder: normalizeRowOrder, clampToDisplayRange: true)
    }

    /// Read FITS pixels as linear data without clamping finite values to the display 0…1 range.
    ///
    /// Calibration masters can legitimately contain flat-normalization values above 1.0
    /// (and finite signed values in other calibration data). The default `read` entry point
    /// keeps its normalized-display contract; this entry point is for calibration/math paths.
    public static func readLinear(_ data: Data, normalizeRowOrder: Bool = true) throws -> FITSImage {
        try read(data, normalizeRowOrder: normalizeRowOrder, clampToDisplayRange: false)
    }

    private static func read(_ data: Data,
                             normalizeRowOrder: Bool,
                             clampToDisplayRange: Bool) throws -> FITSImage {
        noteDecodeForTesting()   // test seam (see property doc); lock-guarded, harmless in production
        let data = data.startIndex == 0 ? data : Data(data)
        let h = try readHeader(data)
        guard data.count >= h.minimumFileSize else {
            throw FITSError.truncatedData(expected: h.minimumFileSize, actual: data.count)
        }
        let pixelBytes = data.subdata(in: h.headerBytes..<(h.headerBytes + h.dataBytes))
        let n = h.dims.reduce(1, *)
        var px = [Float](repeating: 0, count: n)

        func physical(_ v: Double) -> Double { h.bzero + h.bscale * v }

        pixelBytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            switch h.bitpix {
            case 8:
                for i in 0..<n { px[i] = Float(physical(Double(buf[i])) / 255.0) }
            case 16:
                for i in 0..<n {
                    let word16 = buf.loadUnaligned(fromByteOffset: i * MemoryLayout<Int16>.size, as: Int16.self)
                    px[i] = Float(physical(Double(Int16(bigEndian: word16))) / 65535.0)
                }
            case 32:
                for i in 0..<n {
                    let word32 = buf.loadUnaligned(fromByteOffset: i * MemoryLayout<Int32>.size, as: Int32.self)
                    px[i] = Float(physical(Double(Int32(bigEndian: word32))) / 4294967295.0)
                }
            case -32:
                for i in 0..<n {
                    let bits32 = buf.loadUnaligned(fromByteOffset: i * MemoryLayout<UInt32>.size, as: UInt32.self)
                    px[i] = Float(physical(Double(Float(bitPattern: UInt32(bigEndian: bits32)))))
                }
            case -64:
                for i in 0..<n {
                    let bits64 = buf.loadUnaligned(fromByteOffset: i * MemoryLayout<UInt64>.size, as: UInt64.self)
                    px[i] = Float(physical(Double(bitPattern: UInt64(bigEndian: bits64))))
                }
            default:
                preconditionFailure("validated in readHeader")
            }
        }
        // Swift's min/max do NOT clamp NaN (comparisons with NaN are false), so
        // non-finite samples (NaN/±Inf from BITPIX -32/-64 data) map to 0 explicitly.
        // The default reader also clamps to the normalized display 0…1 range; linear
        // calibration reads preserve finite values outside that range.
        for i in 0..<n {
            guard px[i].isFinite else {
                px[i] = 0
                continue
            }
            if clampToDisplayRange {
                px[i] = min(max(px[i], 0), 1)
            }
        }

        if h.bottomUp && normalizeRowOrder {
            let plane = h.width * h.height
            for c in 0..<h.channels {
                for row in 0..<(h.height / 2) {
                    let a = c * plane + row * h.width
                    let b = c * plane + (h.height - 1 - row) * h.width
                    for col in 0..<h.width { px.swapAt(a + col, b + col) }
                }
            }
        }
        return FITSImage(width: h.width, height: h.height, channels: h.channels, pixels: px)
    }

    private static func doubleValue(_ key: String,
                                    default defaultValue: Double,
                                    cards: [String: String]) throws -> Double {
        guard let raw = cards[key] else { return defaultValue }
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return defaultValue
        }
        let fitsNumber = raw
            .replacingOccurrences(of: "D", with: "E")
            .replacingOccurrences(of: "d", with: "E")
        guard let value = Double(fitsNumber), value.isFinite else {
            throw FITSError.malformedHeader("bad \(key)")
        }
        return value
    }
}
