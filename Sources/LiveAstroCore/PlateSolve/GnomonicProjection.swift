import Foundation

/// Standard gnomonic (TAN) tangent-plane projection about a center. `project` returns standard
/// coordinates (xi, eta) in RADIANS; `deproject` is its inverse, returning degrees.
public enum GnomonicProjection {
    static let d2r = Double.pi / 180, r2d = 180 / Double.pi

    public static func project(ra: Double, dec: Double,
                               centerRA: Double, centerDec: Double) -> (xi: Double, eta: Double) {
        let r = ra * d2r, d = dec * d2r, r0 = centerRA * d2r, d0 = centerDec * d2r
        let cosc = sin(d0) * sin(d) + cos(d0) * cos(d) * cos(r - r0)
        let xi = cos(d) * sin(r - r0) / cosc
        let eta = (cos(d0) * sin(d) - sin(d0) * cos(d) * cos(r - r0)) / cosc
        return (xi, eta)
    }

    public static func deproject(xi: Double, eta: Double,
                                 centerRA: Double, centerDec: Double) -> (ra: Double, dec: Double) {
        let r0 = centerRA * d2r, d0 = centerDec * d2r
        let rho = (xi * xi + eta * eta).squareRoot()
        if rho < 1e-12 { return (centerRA, centerDec) }
        let c = atan(rho)
        let dec = asin(cos(c) * sin(d0) + eta * sin(c) * cos(d0) / rho)
        let ra = r0 + atan2(xi * sin(c), rho * cos(d0) * cos(c) - eta * sin(d0) * sin(c))
        let raDeg = (ra * r2d).truncatingRemainder(dividingBy: 360)
        return ((raDeg + 360).truncatingRemainder(dividingBy: 360), dec * r2d)
    }
}
