import Foundation

public struct FITSHeader: Equatable {
    public let bitpix: Int
    public let dims: [Int]          // [NAXIS1, NAXIS2] or [NAXIS1, NAXIS2, 3]
    public let bscale: Double
    public let bzero: Double
    public let bottomUp: Bool       // ROWORDER, FITS default is bottom-up
    public let headerBytes: Int

    public var width: Int { dims[0] }
    public var height: Int { dims[1] }
    public var channels: Int { dims.count == 3 ? dims[2] : 1 }
    public var dataBytes: Int { dims.reduce(1, *) * abs(bitpix) / 8 }
    /// Watcher completeness check: file must be at least this many bytes.
    public var minimumFileSize: Int { headerBytes + dataBytes }
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
