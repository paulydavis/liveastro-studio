import Foundation

/// 2-D similarity transform y = s·R(θ)·x + t (spec §3: alignment model).
public struct SimilarityTransform: Equatable {
    public let scale: Double
    public let rotation: Double
    public let tx: Double
    public let ty: Double

    public init(scale: Double, rotation: Double, tx: Double, ty: Double) {
        self.scale = scale; self.rotation = rotation; self.tx = tx; self.ty = ty
    }

    public static let identity = SimilarityTransform(scale: 1, rotation: 0, tx: 0, ty: 0)

    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        let c = cos(rotation) * scale, s = sin(rotation) * scale
        return (c * x - s * y + tx, s * x + c * y + ty)
    }

    public func inverse() -> SimilarityTransform {
        let invScale = 1 / scale
        let invRot = -rotation
        let c = cos(invRot) * invScale, s = sin(invRot) * invScale
        return SimilarityTransform(scale: invScale, rotation: invRot,
                                   tx: -(c * tx - s * ty), ty: -(s * tx + c * ty))
    }

    public func liftedToFullResolution() -> SimilarityTransform {
        let c = cos(rotation) * scale, s = sin(rotation) * scale
        // t_full = 2t + (I − sR)·(0.5, 0.5)
        let txF = 2 * tx + 0.5 - (c * 0.5 - s * 0.5)
        let tyF = 2 * ty + 0.5 - (s * 0.5 + c * 0.5)
        return SimilarityTransform(scale: scale, rotation: rotation, tx: txF, ty: tyF)
    }
}
