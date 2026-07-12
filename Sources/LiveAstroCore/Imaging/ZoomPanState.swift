import CoreGraphics

/// Non-destructive zoom/pan for the live display. `scale` 1.0 = fit whole frame,
/// clamped to [1, maxScale]; `offset` is the pan (points) clamped so the scaled
/// content always covers the view (no empty margins). Pure value type — the
/// SwiftUI view owns the gestures; this owns the clamp math.
public struct ZoomPanState: Equatable {
    public var scale: CGFloat
    public var offset: CGSize

    public static let maxScale: CGFloat = 8
    public static let fit = ZoomPanState(scale: 1, offset: .zero)

    public init(scale: CGFloat = 1, offset: CGSize = .zero) {
        self.scale = scale
        self.offset = offset
    }

    /// Clamp a scale to [1, maxScale].
    public static func clampScale(_ s: CGFloat) -> CGFloat {
        min(max(s, 1), maxScale)
    }

    /// Clamp `proposed` so the content (of `fittedContentSize` at scale 1, the
    /// letterboxed size under scaledToFit) still covers `viewSize` at `scale`.
    /// Per axis: overflow = scaled − view; maxOffset = overflow/2; clamp to
    /// ±maxOffset (0 when the axis doesn't overflow). Empty sizes → .zero.
    public static func clampedOffset(_ proposed: CGSize, scale: CGFloat,
                                     viewSize: CGSize, fittedContentSize: CGSize) -> CGSize {
        guard viewSize.width > 0, viewSize.height > 0,
              fittedContentSize.width > 0, fittedContentSize.height > 0 else { return .zero }
        let maxX = max(0, (fittedContentSize.width * scale - viewSize.width) / 2)
        let maxY = max(0, (fittedContentSize.height * scale - viewSize.height) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }
}
