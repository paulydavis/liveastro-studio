import Foundation

/// A catalog star in celestial coordinates (Gaia DR3 bright subset). Distinct from
/// `StarDetector.Star`, which is screen-space; the plate-solver projects catalog → screen.
public struct CatalogStar: Equatable {
    public let ra: Float    // decimal degrees [0,360)
    public let dec: Float   // decimal degrees [-90,90]
    public let mag: Float   // Gaia G magnitude
    public init(ra: Float, dec: Float, mag: Float) { self.ra = ra; self.dec = dec; self.mag = mag }
}
