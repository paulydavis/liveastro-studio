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

    /// Supported BITPIX values and the per-axis ceiling — the constraints readHeader also enforces.
    public static let supportedBitpix: Set<Int> = [8, 16, 32, -32, -64]
    public static let maxAxisLength = 100_000

    /// FAILABLE + VALIDATING. A FITSHeader can never hold hostile values: this returns nil for a dims
    /// array that isn't 2-D or 3-D, any non-positive or oversized (> maxAxisLength) axis, a 3-D cube
    /// whose 3rd axis isn't 3 channels, an unsupported BITPIX, or a negative headerBytes. Closing
    /// hostile DIRECT construction at the source (not accessor-by-accessor) lets width/height/dataBytes
    /// stay simple and trap-free — the bounds guarantee the pixel-count product can't overflow or go
    /// non-positive, and the supported-BITPIX set means abs(bitpix) can never hit Int.min.
    public init?(bitpix: Int, dims: [Int], bscale: Double, bzero: Double,
                 bottomUp: Bool, headerBytes: Int, keywords: [String: String] = [:]) {
        guard dims.count == 2 || dims.count == 3,
              dims.allSatisfy({ $0 > 0 && $0 <= FITSHeader.maxAxisLength }),
              dims.count < 3 || dims[2] == 3,
              FITSHeader.supportedBitpix.contains(bitpix),
              headerBytes >= 0 else { return nil }
        self.bitpix = bitpix
        self.dims = dims
        self.bscale = bscale
        self.bzero = bzero
        self.bottomUp = bottomUp
        self.headerBytes = headerBytes
        self.keywords = keywords
    }

    public var width: Int { dims[0] }       // safe: the validating init guarantees dims.count is 2 or 3
    public var height: Int { dims[1] }
    public var channels: Int { dims.count == 3 ? dims[2] : 1 }
    /// Safe by construction: the validating init bounds dims (≤ maxAxisLength) and BITPIX (supported
    /// set), so this product can neither overflow Int nor be non-positive, and abs() can't trap.
    public var dataBytes: Int { dims.reduce(1, *) * abs(bitpix) / 8 }
    /// Watcher completeness check. Saturating add — headerBytes is validated ≥ 0 but not upper-bounded.
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
