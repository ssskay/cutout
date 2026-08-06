import CoreGraphics
import Foundation

extension CGRect {
    /// True when this rect is safe to rasterise: real numbers, non-empty, and not
    /// Core Image's infinite extent (which `CIImage(color:)` and `clampedToExtent()`
    /// both hand back and which would otherwise reach a bitmap allocation).
    var isRasterisable: Bool {
        !isNull && !isInfinite && !isEmpty
            && origin.x.isFinite && origin.y.isFinite
            && width.isFinite && height.isFinite
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CGSize {
    var isRasterisable: Bool {
        width.isFinite && height.isFinite && width >= 1 && height >= 1
    }
}

/// Converts a Vision rect (normalized, bottom-left origin) into pixel coordinates
/// with a **top-left** origin, which is the space everything else in this app uses.
func pixelRectTopLeft(fromNormalized rect: CGRect, imageSize: CGSize) -> CGRect {
    let x = rect.origin.x * imageSize.width
    let w = rect.width * imageSize.width
    let h = rect.height * imageSize.height
    let yBottomUp = rect.origin.y * imageSize.height
    let yTopDown = imageSize.height - (yBottomUp + h)
    return CGRect(x: x, y: yTopDown, width: w, height: h)
}
