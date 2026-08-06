import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Tuning for the mask edge. Defaults are what looked right on hair-heavy photos
/// against pure white; the CLI harness (`scripts/masktest.sh`) exposes them as
/// flags so they can be re-tuned against a real photo rather than by taste.
struct MaskRefinement: Equatable {
    /// Pixels to pull the mask inward, in *source* pixels. Vision's mask sits a
    /// touch outside the true subject edge; without this you get a rim of the
    /// original background fringing the subject, which is glaring on white.
    var erodeRadius: Double = 1.0

    /// Gaussian softening applied after the erode, in source pixels. Keeps the
    /// edge from looking laser-cut without reintroducing the halo.
    var featherRadius: Double = 0.75

    static let none = MaskRefinement(erodeRadius: 0, featherRadius: 0)
    static let `default` = MaskRefinement()
}

struct MaskResult {
    /// Refined mask, source resolution, value 0…1 replicated into R, G, B and A.
    let mask: CIImage
    /// Size Vision actually returned, before any upscale. Logged because a mask
    /// far below source resolution is the first thing to suspect on a soft edge.
    let visionSize: CGSize
    /// Source image size the mask was scaled to.
    let sourceSize: CGSize
    let instanceCount: Int
    var wasUpscaled: Bool { visionSize != sourceSize }
}

/// Wraps `VNGenerateForegroundInstanceMaskRequest` — the same subject-lifting
/// model Preview's "Remove Background" uses, already present on every macOS 14+
/// machine. No download, no network, no per-image cost.
final class CutoutEngine {
    let context: CIContext

    init(context: CIContext = CutoutEngine.makeContext()) {
        self.context = context
    }

    /// A context with a wide linear working space so P3 sources survive the
    /// round trip without being clipped to sRGB mid-pipeline.
    static func makeContext() -> CIContext {
        let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [
            .workingColorSpace: working,
            .cacheIntermediates: false,
        ])
    }

    // MARK: - Mask

    func generateMask(for image: CIImage,
                      refinement: MaskRefinement = .default,
                      label: String = "") throws -> MaskResult {
        var watch = Stopwatch()
        let sourceExtent = image.extent
        guard sourceExtent.isRasterisable, sourceExtent.size.isRasterisable else {
            throw CutoutError.maskGenerationFailed("source image has no finite extent")
        }

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()

        do {
            try handler.perform([request])
        } catch {
            throw CutoutError.maskGenerationFailed(error.localizedDescription)
        }

        guard let observation = request.results?.first as? VNInstanceMaskObservation,
              !observation.allInstances.isEmpty else {
            Log.error("no-foreground", [("file", label), ("src", sourceExtent.size)])
            throw CutoutError.noForeground
        }

        // Lift *every* instance Vision found, not just the most prominent one:
        // a listing photo of a boxed figure is routinely two instances (box + lid),
        // and taking only the first silently amputates half the product.
        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
        } catch {
            throw CutoutError.maskGenerationFailed(error.localizedDescription)
        }

        // No colour management on the mask — these are coverage values, not colour.
        let raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let visionSize = raw.extent.size

        var mask = normalizeChannels(raw)
        mask = scale(mask, to: sourceExtent)
        let maskMS = watch.lap()

        Log.stage("mask", [
            ("file", label),
            ("instances", observation.allInstances.count),
            ("mask", visionSize),
            ("src", sourceExtent.size),
            ("upscaled", visionSize != sourceExtent.size),
        ], ms: maskMS)

        mask = refine(mask, refinement: refinement, extent: sourceExtent)
        if refinement != .none {
            Log.stage("refine", [
                ("file", label),
                ("erode", refinement.erodeRadius),
                ("feather", refinement.featherRadius),
            ], ms: watch.lap())
        }

        return MaskResult(mask: mask,
                          visionSize: visionSize,
                          sourceSize: sourceExtent.size,
                          instanceCount: observation.allInstances.count)
    }

    /// Vision hands back a one-component buffer. `CIBlendWithMask` has read the
    /// mask's alpha in some releases and its luminance in others, so copy the
    /// single channel into all four and stop caring which.
    private func normalizeChannels(_ image: CIImage) -> CIImage {
        let one = CIVector(x: 1, y: 0, z: 0, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": one,
            "inputGVector": one,
            "inputBVector": one,
            "inputAVector": one,
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }

    /// Lanczos, never nearest-neighbour or affine-default: the mask comes back
    /// well below source resolution, and a box filter turns every hair edge into
    /// visible stair-steps that no amount of feathering hides.
    private func scale(_ mask: CIImage, to target: CGRect) -> CIImage {
        let from = mask.extent
        guard from.width >= 1, from.height >= 1 else { return mask }
        if abs(from.width - target.width) < 0.5 && abs(from.height - target.height) < 0.5 {
            return mask.transformed(by: CGAffineTransform(translationX: target.minX - from.minX,
                                                          y: target.minY - from.minY))
        }

        let sy = target.height / from.height
        let sx = target.width / from.width

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = mask.clampedToExtent()
        filter.scale = Float(sy)
        filter.aspectRatio = Float(sx / sy)
        guard let scaled = filter.outputImage else { return mask }

        // clampedToExtent() gives an infinite image; crop it back to the target
        // rect so downstream extent maths stays finite.
        return scaled.cropped(to: CGRect(origin: .zero, size: target.size))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
    }

    /// Erode first, then blur. Reversing them just blurs the halo instead of
    /// removing it.
    private func refine(_ mask: CIImage, refinement: MaskRefinement, extent: CGRect) -> CIImage {
        var out = mask

        if refinement.erodeRadius > 0 {
            // CIMorphologyMinimum takes the darkest value in the radius, which
            // shrinks the lit (subject) region — that is the erode.
            out = out.clampedToExtent()
                .applyingFilter("CIMorphologyMinimum",
                                parameters: [kCIInputRadiusKey: refinement.erodeRadius])
                .cropped(to: extent)
        }

        if refinement.featherRadius > 0 {
            out = out.clampedToExtent()
                .applyingFilter("CIGaussianBlur",
                                parameters: [kCIInputRadiusKey: refinement.featherRadius])
                .cropped(to: extent)
        }

        return out
    }

    // MARK: - Composite

    /// Blends `source` over `backdrop` using `mask`. With `.transparent` the
    /// result carries straight alpha and is ready for a PNG.
    func composite(source: CIImage, mask: CIImage, backdrop: Backdrop) -> CIImage {
        let extent = source.extent
        let background: CIImage
        switch backdrop {
        case .transparent:
            background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        case .white:
            background = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
        case .custom(let color):
            background = CIImage(color: color.ciColor).cropped(to: extent)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = source
        blend.backgroundImage = background
        blend.maskImage = mask
        return (blend.outputImage ?? source).cropped(to: extent)
    }

    /// Tight bounding box of the subject in source pixels, top-left origin.
    func subjectBoundingBox(mask: CIImage) -> (box: CGRect, bitmap: MaskBitmap)? {
        guard let bitmap = MaskBitmap(mask: mask, context: context),
              let box = bitmap.boundingBox() else { return nil }
        return (box, bitmap)
    }
}
