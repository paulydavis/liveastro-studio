import Foundation

public enum FITSReader {

    public static func readHeader(_ data: Data) throws -> FITSHeader {
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
            let base = block * 2880
            guard base + 2880 <= data.count else { throw FITSError.truncatedHeader }
            for i in 0..<36 {
                let start = base + i * 80
                guard let card = String(data: data.subdata(in: start..<(start + 80)), encoding: .ascii) else {
                    throw FITSError.malformedHeader("non-ASCII card at byte \(start)")
                }
                let key = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
                if key == "END" { headerBytes = base + 2880; break }
                let idx8 = card.index(card.startIndex, offsetBy: 8)
                if card[idx8...].hasPrefix("= ") {
                    let raw = String(card[card.index(idx8, offsetBy: 2)...])
                    let value = raw.split(separator: "/", maxSplits: 1)[0]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                        .trimmingCharacters(in: .whitespaces)
                    cards[key] = value
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
        let bscale = cards["BSCALE"].flatMap(Double.init) ?? 1
        let bzero = cards["BZERO"].flatMap(Double.init) ?? 0
        let bottomUp = (cards["ROWORDER"] ?? "BOTTOM-UP").uppercased() != "TOP-DOWN"
        return FITSHeader(bitpix: bitpix, dims: dims, bscale: bscale, bzero: bzero,
                          bottomUp: bottomUp, headerBytes: headerBytes!)
    }

    public static func read(_ data: Data) throws -> FITSImage {
        let h = try readHeader(data)
        guard data.count >= h.minimumFileSize else {
            throw FITSError.truncatedData(expected: h.minimumFileSize, actual: data.count)
        }
        let raw = data.subdata(in: h.headerBytes..<(h.headerBytes + h.dataBytes))
        let n = h.dims.reduce(1, *)
        var px = [Float](repeating: 0, count: n)

        func physical(_ v: Double) -> Double { h.bzero + h.bscale * v }

        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            switch h.bitpix {
            case 8:
                for i in 0..<n { px[i] = Float(physical(Double(buf[i])) / 255.0) }
            case 16:
                for i in 0..<n {
                    let raw = buf.loadUnaligned(fromByteOffset: i * MemoryLayout<Int16>.size, as: Int16.self)
                    px[i] = Float(physical(Double(Int16(bigEndian: raw))) / 65535.0)
                }
            case 32:
                for i in 0..<n {
                    let raw = buf.loadUnaligned(fromByteOffset: i * MemoryLayout<Int32>.size, as: Int32.self)
                    px[i] = Float(physical(Double(Int32(bigEndian: raw))) / 4294967295.0)
                }
            case -32:
                for i in 0..<n {
                    let raw = buf.loadUnaligned(fromByteOffset: i * MemoryLayout<UInt32>.size, as: UInt32.self)
                    px[i] = Float(physical(Double(Float(bitPattern: UInt32(bigEndian: raw)))))
                }
            case -64:
                for i in 0..<n {
                    let raw = buf.loadUnaligned(fromByteOffset: i * MemoryLayout<UInt64>.size, as: UInt64.self)
                    px[i] = Float(physical(Double(bitPattern: UInt64(bigEndian: raw))))
                }
            default:
                preconditionFailure("validated in readHeader")
            }
        }
        // Clamp all pixel values to normalized 0…1 range (FITSImage contract)
        for i in 0..<n { px[i] = min(max(px[i], 0), 1) }

        if h.bottomUp {
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
}
