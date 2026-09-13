import Foundation

/// World Coordinate System solution for a frame: where it points, how it's rotated, its scale.
public struct WCS: Equatable {
    public let centerRA: Double          // degrees [0,360)
    public let centerDec: Double         // degrees [-90,90]
    public let rotationDegrees: Double   // position angle of image +y ("up") relative to north
    public let pixelScaleArcsec: Double
    public let parity: Bool              // true = mirrored (sky flipped left-right)
    public let inlierCount: Int          // matched catalog stars supporting the solve
    public init(centerRA: Double, centerDec: Double, rotationDegrees: Double,
                pixelScaleArcsec: Double, parity: Bool, inlierCount: Int) {
        self.centerRA = centerRA; self.centerDec = centerDec; self.rotationDegrees = rotationDegrees
        self.pixelScaleArcsec = pixelScaleArcsec; self.parity = parity; self.inlierCount = inlierCount
    }
}
