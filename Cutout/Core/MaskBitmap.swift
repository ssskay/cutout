import CoreGraphics
import CoreImage
import Foundation

/// An 8-bit grayscale snapshot of a mask, in **top-left origin** pixel coordinates.
///
/// Core Image works bottom-up and Vision works in normalized bottom-left space;
/// every geometry decision in this app (crown row, chin row, subject bounding box)
/// is easier to reason about — and to check against a log line — in the same
/// top-left space the exported file uses. This type is the single place that
/// flip happens, and every accessor returns **source** pixel coordinates so
/// callers never have to know it downsamples.
struct MaskBitmap {
    /// Resolution of the internal scan buffer.
    let width: Int
    let height: Int
    /// Full-resolution size of the mask this was built from.
    let sourceSize: CGSize
    /// Scan pixels per source pixel (≤ 1).
    let scale: CGFloat

    private let bytes: [UInt8]

    /// Rasterises `mask`, capping the long edge at `maxDimension`.
    ///
    /// A 4000 px photo does not need a 4000 px scan: the bounding box and crown
    /// row are the only things read out of it, and at a 2048 px cap the worst-case
    /// crown error is about two source pixels — under 0.05 mm once mapped into a
    /// 45 mm ID frame. Uncapped, this single step dominated the batch time.
    init?(mask: CIImage, context: CIContext, maxDimension: Int = 2048) {
        let extent = mask.extent
        guard extent.isRasterisable, extent.size.isRasterisable else { return nil }

        let fullW = extent.width
        let fullH = extent.height
        let cap = CGFloat(max(64, maxDimension))
        let scale = min(1, cap / max(fullW, fullH))

        let w = max(1, Int((fullW * scale).rounded()))
        let h = max(1, Int((fullH * scale).rounded()))

        // Go through CGImage rather than CIContext.render(toBitmap:) because
        // CGImage's row order is unambiguous: row 0 is the top of the image.
        guard let cg = context.createCGImage(mask, from: extent) else { return nil }

        var buffer = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: w,
                                      height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        self.width = w
        self.height = h
        self.sourceSize = CGSize(width: fullW, height: fullH)
        self.scale = scale
        self.bytes = buffer
    }

    @inline(__always)
    func value(x: Int, y: Int) -> UInt8 {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return bytes[y * width + x]
    }

    /// Tight bounding box of everything at or above `threshold`, in **source**
    /// pixels, top-left origin. Returns nil for an entirely empty mask.
    func boundingBox(threshold: UInt8 = 12) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            var rowMinX = -1
            var rowMaxX = -1
            for x in 0..<width where bytes[row + x] >= threshold {
                if rowMinX < 0 { rowMinX = x }
                rowMaxX = x
            }
            if rowMaxX >= 0 {
                if y < minY { minY = y }
                maxY = y
                if rowMinX < minX { minX = rowMinX }
                if rowMaxX > maxX { maxX = rowMaxX }
            }
        }
        guard maxX >= 0 else { return nil }

        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return toSource(box)
    }

    /// Topmost lit row inside `sourceColumns`, returned in **source** pixels.
    ///
    /// `minRun` (also in source pixels) is what separates a head from a stray
    /// backlit hair or a speck of mask noise. Scanning for a horizontal *run*
    /// rather than a single pixel is why this beats extrapolating the crown from
    /// Vision's face box, which stops at the forehead and knows nothing about
    /// hair volume.
    func topmostRow(inColumns sourceColumns: Range<Int>,
                    threshold: UInt8 = 128,
                    minRun: Int = 3) -> CGFloat? {
        let lo = max(0, Int((CGFloat(sourceColumns.lowerBound) * scale).rounded(.down)))
        let hi = min(width, Int((CGFloat(sourceColumns.upperBound) * scale).rounded(.up)))
        guard lo < hi else { return nil }

        let scaledRun = max(1, Int((CGFloat(minRun) * scale).rounded()))

        for y in 0..<height {
            let row = y * width
            var run = 0
            for x in lo..<hi {
                if bytes[row + x] >= threshold {
                    run += 1
                    if run >= scaledRun {
                        return CGFloat(y) / scale
                    }
                } else {
                    run = 0
                }
            }
        }
        return nil
    }

    /// Fraction of pixels at or above `threshold`. A mask covering ~everything or
    /// ~nothing usually means Vision misfired, so this gets logged.
    func coverage(threshold: UInt8 = 128) -> Double {
        var lit = 0
        for b in bytes where b >= threshold { lit += 1 }
        return Double(lit) / Double(max(1, width * height))
    }

    private func toSource(_ rect: CGRect) -> CGRect {
        guard scale > 0, scale < 1 else { return rect }
        let inverse = 1 / scale
        return CGRect(x: rect.minX * inverse,
                      y: rect.minY * inverse,
                      width: rect.width * inverse,
                      height: rect.height * inverse)
            .intersection(CGRect(origin: .zero, size: sourceSize))
    }
}
