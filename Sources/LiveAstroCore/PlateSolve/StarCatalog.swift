import Foundation

/// A bright-star catalog (Gaia DR3, G ≤ 8.5) loaded from the compact `brightstars.bin` resource.
/// Little-endian: magic "LASC" + UInt32 version + UInt32 count, then count × {ra,dec,mag} Float32.
/// Records are stored sorted by ascending declination (enables the dec-band query in Task 2).
public struct StarCatalog {
    public enum CatalogError: Error, Equatable { case badMagic, badVersion, truncated }

    static let magic: [UInt8] = Array("LASC".utf8)
    static let version: UInt32 = 1
    static let headerSize = 12
    static let recordSize = 12

    public let stars: [CatalogStar]          // sorted by ascending dec
    public var count: Int { stars.count }

    /// Encode stars (sorted by ascending dec) to the binary format. Used by the generator + tests.
    public static func encode(_ stars: [CatalogStar]) -> Data {
        let sorted = stars.sorted { $0.dec < $1.dec }
        var data = Data(magic)
        var v = version.littleEndian, c = UInt32(sorted.count).littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
        for s in sorted {
            for var f in [s.ra.bitPattern.littleEndian, s.dec.bitPattern.littleEndian, s.mag.bitPattern.littleEndian] {
                withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize else { throw CatalogError.truncated }
        guard Array(bytes[0..<4]) == Self.magic else { throw CatalogError.badMagic }
        func u32(_ off: Int) -> UInt32 {
            UInt32(bytes[off]) | UInt32(bytes[off+1]) << 8 | UInt32(bytes[off+2]) << 16 | UInt32(bytes[off+3]) << 24
        }
        func f32(_ off: Int) -> Float { Float(bitPattern: u32(off)) }
        guard u32(4) == Self.version else { throw CatalogError.badVersion }
        let n = Int(u32(8))
        guard bytes.count >= Self.headerSize + n * Self.recordSize else { throw CatalogError.truncated }
        var out = [CatalogStar](); out.reserveCapacity(n)
        for i in 0..<n {
            let o = Self.headerSize + i * Self.recordSize
            out.append(CatalogStar(ra: f32(o), dec: f32(o+4), mag: f32(o+8)))
        }
        self.stars = out
    }
}
