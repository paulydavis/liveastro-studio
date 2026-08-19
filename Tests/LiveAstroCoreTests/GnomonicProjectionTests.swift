import XCTest
@testable import LiveAstroCore

final class GnomonicProjectionTests: XCTestCase {
    func testProjectDeprojectRoundTrip() {
        // Centers incl. mid-sky, near-pole, and RA-seam; offsets within a few degrees (a FOV).
        let centers: [(Double, Double)] = [(198.8, 41.35), (10.0, 85.0), (0.5, -3.0)]
        for (ra0, dec0) in centers {
            for dra in [-1.5, 0.0, 1.7] {
                for ddec in [-1.2, 0.0, 1.3] {
                    let ra = (ra0 + dra / cos(dec0 * .pi/180) + 360).truncatingRemainder(dividingBy: 360)
                    let dec = dec0 + ddec
                    let p = GnomonicProjection.project(ra: ra, dec: dec, centerRA: ra0, centerDec: dec0)
                    let b = GnomonicProjection.deproject(xi: p.xi, eta: p.eta, centerRA: ra0, centerDec: dec0)
                    XCTAssertEqual(b.dec, dec, accuracy: 1e-7, "dec round-trip @\(ra0),\(dec0)")
                    let dRA = ((b.ra - ra + 540).truncatingRemainder(dividingBy: 360)) - 180
                    XCTAssertEqual(dRA, 0, accuracy: 1e-7, "ra round-trip @\(ra0),\(dec0)")
                }
            }
        }
    }
}
