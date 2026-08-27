import Foundation

public struct FITSHeader: Equatable {
    public let bitpix: Int
    public let dims: [Int]          // [NAXIS1, NAXIS2] or [NAXIS1, NAXIS2, 3]
    public let bscale: Double
    public let bzero: Double
    public let bottomUp: Bool       // ROWORDER, FITS default is bottom-up
    public let headerBytes: Int
    /// Every KEY = value card: key uppercased/trimmed, string values unquoted/trimmed.
    public let keywords: [String: String]

    public init(bitpix: Int, dims: [Int], bscale: Double, bzero: Double,
                bottomUp: Bool, headerBytes: Int, keywords: [String: String] = [:]) {
        self.bitpix = bitpix
        self.dims = dims
        self.bscale = bscale
        self.bzero = bzero
        self.bottomUp = bottomUp
        self.headerBytes = headerBytes
        self.keywords = keywords
    }

    public var width: Int { dims[0] }
    public var height: Int { dims[1] }
    public var channels: Int { dims.count == 3 ? dims[2] : 1 }
    /// Bytes of pixel data. Overflow-SATURATES to Int.max rather than trapping, so a hostile header
    /// (huge NAXIS) can't crash a public caller; the watcher then treats such a file as never
    /// complete (a real file size can't reach Int.max), which is the safe outcome.
    public var dataBytes: Int {
        var acc = 1
        for d in dims {
            let (p, o) = acc.multipliedReportingOverflow(by: d)
            if o { return Int.max }
            acc = p
        }
        // abs(bitpix) traps for bitpix == Int.min; take the magnitude safely (saturate that
        // impossible-in-practice case to Int.max rather than crash a public caller).
        guard let absBitpix = Int(exactly: bitpix.magnitude) else { return Int.max }
        let (bytes, o) = acc.multipliedReportingOverflow(by: absBitpix)
        return o ? Int.max : bytes / 8
    }
    /// Watcher completeness check: file must be at least this many bytes. Saturating add.
    public var minimumFileSize: Int {
        let (s, o) = headerBytes.addingReportingOverflow(dataBytes)
        return o ? Int.max : s
    }

    public var bayerPattern: String? { keywords["BAYERPAT"] }
    public var dateObs: String? { keywords["DATE-OBS"] }
}

public struct FITSImage: Equatable {
    public let width: Int
    public let height: Int
    public let channels: Int
    /// Planar (channel-major), row-major top-down within each plane, normalized 0…1.
    public let pixels: [Float]
}

public enum FITSError: Error, Equatable {
    case notFITS
    case truncatedHeader
    case truncatedData(expected: Int, actual: Int)
    case unsupported(String)
    case malformedHeader(String)
}
