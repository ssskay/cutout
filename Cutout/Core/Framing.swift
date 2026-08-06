import CoreGraphics
import CoreImage
import Foundation

/// User overrides applied on top of the automatic ID crop.
///
/// The automatic placement is a starting point, not an answer — Vision's face box
/// and the crown scan can both be off on hats, dark hair against a dark room, or
/// a tilted head. These three numbers are the escape hatch.
struct IDAdjustment: Equatable {
    /// Multiplier on the auto scale. 1.0 = the auto-computed 32 mm head.
    var scale: Double = 1.0
    /// Nudge in output pixels, positive = right / down.
    var offsetX: Double = 0
    var offsetY: Double = 0

    static let identity = IDAdjustment()
    var isIdentity: Bool { self == .identity }
}

/// The transform that places a source image into an output frame.
struct Placement {
    /// Uniform scale applied to the source.
    var scale: Double
    /// Translation in output pixels, applied after scaling, top-left origin.
    var translateX: Double
    var translateY: Double
    /// Output frame size in pixels.
    var outputSize: CGSize

    /// Core Image works bottom-up; convert the top-left-origin translation into
    /// the affine transform CI actually needs.
    func affineTransform(sourceSize: CGSize) -> CGAffineTransform {
        let scaledHeight = sourceSize.height * scale
        // Distance from the output's bottom edge to the scaled image's bottom edge.
        let yFromBottom = outputSize.height - (translateY + scaledHeight)
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: translateX, y: yFromBottom))
    }
}

enum Framing {
    /// Centres `subjectBox` inside `outputSize`, scaled to `fillFraction` of the
    /// frame's shorter constraint. Used by the eBay and Custom presets.
    ///
    /// `fillFraction` 0.90 is the same thing as "5% padding on each side"; it is
    /// applied to both axes, so a tall subject is limited by height and a wide one
    /// by width, and neither ever touches the edge.
    static func centreSubject(subjectBox: CGRect,
                              sourceSize: CGSize,
                              outputSize: CGSize,
                              fillFraction: Double) -> Placement {
        let boxW = max(1, subjectBox.width)
        let boxH = max(1, subjectBox.height)
        let scale = min(outputSize.width * fillFraction / boxW,
                        outputSize.height * fillFraction / boxH)

        // Where the subject's centre lands if we only scaled, then shift it to
        // the frame centre.
        let subjectCentreX = subjectBox.midX * scale
        let subjectCentreY = subjectBox.midY * scale

        return Placement(scale: scale,
                         translateX: outputSize.width / 2 - subjectCentreX,
                         translateY: outputSize.height / 2 - subjectCentreY,
                         outputSize: outputSize)
    }

    /// Places a head per the ICA spec: crown-to-chin at `targetHeadMM`, roughly
    /// `headroomMM` above the crown, face midline on the frame midline.
    static func idPhoto(face: FaceGeometry,
                        sourceSize: CGSize,
                        spec: IDPhotoSpec,
                        adjustment: IDAdjustment) -> Placement {
        let targetHeadPx = spec.pixels(fromVerticalMM: spec.targetHeadMM)
        let autoScale = targetHeadPx / Double(face.crownToChin)
        let scale = autoScale * adjustment.scale

        // Crown sits `headroomMM` below the top edge.
        let crownTargetY = spec.pixels(fromVerticalMM: spec.headroomMM)
        let translateY = crownTargetY - Double(face.crownY) * scale + adjustment.offsetY

        // Face midline on the frame midline.
        let translateX = Double(spec.pixelWidth) / 2 - Double(face.midlineX) * scale + adjustment.offsetX

        return Placement(scale: scale,
                         translateX: translateX,
                         translateY: translateY,
                         outputSize: spec.pixelSize)
    }

    /// The head height, in millimetres of the final frame, that a placement
    /// actually produces. With `IDAdjustment.identity` this equals
    /// `spec.targetHeadMM`; after a manual rescale it is the number that decides
    /// whether the photo is accepted, so it is what the UI shows.
    static func headHeightMM(face: FaceGeometry, placement: Placement, spec: IDPhotoSpec) -> Double {
        spec.mm(fromVerticalPixels: Double(face.crownToChin) * placement.scale)
    }

    /// Renders `image` into `placement.outputSize` over `background`.
    static func render(image: CIImage,
                       placement: Placement,
                       background: Backdrop,
                       context: CIContext) -> CIImage {
        let sourceSize = image.extent.size
        let outputRect = CGRect(origin: .zero, size: placement.outputSize)

        // Move the source to the origin first so a non-zero extent (which
        // `oriented()` can leave behind) doesn't offset every placement.
        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let placed = normalized.transformed(by: placement.affineTransform(sourceSize: sourceSize))

        let backgroundImage: CIImage
        switch background {
        case .transparent:
            backgroundImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
        case .white:
            backgroundImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
        case .custom(let c):
            backgroundImage = CIImage(color: c.ciColor)
        }

        return placed
            .composited(over: backgroundImage.cropped(to: outputRect))
            .cropped(to: outputRect)
    }
}
