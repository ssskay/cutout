import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Where the head is, in source pixels, top-left origin.
struct FaceGeometry {
    /// Vision's face rectangle. Useful for the horizontal midline; useless for
    /// the crown, because it stops around the forehead and ignores hair volume.
    var faceBox: CGRect
    /// Topmost lit row of the mask within the face's horizontal span — the crown,
    /// hair included.
    var crownY: CGFloat
    /// Bottom of the chin.
    var chinY: CGFloat
    /// Vertical midline of the face, used to centre horizontally.
    var midlineX: CGFloat
    /// True when `chinY` came from face landmarks rather than the face box edge.
    var chinFromLandmarks: Bool

    var crownToChin: CGFloat { max(1, chinY - crownY) }
}

enum FaceFinder {
    /// Locates the head for the ID preset.
    ///
    /// Two Vision requests plus a mask scan:
    ///   1. `VNDetectFaceRectanglesRequest` → which face, and its midline.
    ///   2. `VNDetectFaceLandmarksRequest`  → a real chin point (the face box's
    ///      bottom edge sits high and inconsistently on tilted heads).
    ///   3. mask scan → the crown, from the alpha silhouette.
    static func locate(in image: CIImage,
                       mask: MaskBitmap,
                       label: String = "") throws -> FaceGeometry {
        var watch = Stopwatch()
        let size = image.extent.size

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let rectRequest = VNDetectFaceRectanglesRequest()
        let landmarkRequest = VNDetectFaceLandmarksRequest()

        do {
            try handler.perform([rectRequest, landmarkRequest])
        } catch {
            throw CutoutError.maskGenerationFailed("face detection: \(error.localizedDescription)")
        }

        let faces = (rectRequest.results ?? [])
        guard !faces.isEmpty else {
            Log.error("no-face", [("file", label), ("src", size)])
            throw CutoutError.noFaceDetected
        }

        // Group shots happen by accident; take the biggest face rather than the
        // first, which is whichever one Vision happened to score highest.
        let face = faces.max(by: { $0.boundingBox.area < $1.boundingBox.area })!
        let faceBox = pixelRectTopLeft(fromNormalized: face.boundingBox, imageSize: size)

        // --- chin ---------------------------------------------------------
        var chinY = faceBox.maxY
        var chinFromLandmarks = false
        if let landmarkFace = bestLandmarkFace(landmarkRequest.results, matching: face),
           let contour = landmarkFace.landmarks?.faceContour {
            let points = contour.pointsInImage(imageSize: size)   // bottom-left origin
            if let lowest = points.map({ size.height - $0.y }).max() {
                chinY = lowest
                chinFromLandmarks = true
            }
        }

        // --- crown --------------------------------------------------------
        // Widen the scan span past the face box: hair and ears sit outside it,
        // and a bun or a high ponytail is exactly the case where the face box
        // would put the crown far too low.
        let widen = faceBox.width * 0.25
        let lo = Int((faceBox.minX - widen).rounded(.down))
        let hi = Int((faceBox.maxX + widen).rounded(.up))
        // Require a run wide enough to be a head, not a stray hair or mask speck.
        let minRun = max(3, Int(faceBox.width * 0.05))

        let crownY: CGFloat
        if let crownRow = mask.topmostRow(inColumns: lo..<hi, minRun: minRun) {
            crownY = crownRow
        } else {
            // Fall back to the face box top with a hair allowance rather than
            // failing outright — and say so in the log, because this estimate is
            // the single most likely cause of a bad crop.
            crownY = max(0, faceBox.minY - faceBox.height * 0.35)
            Log.warn("crown-fallback", [
                ("file", label),
                ("reason", "no mask run in face span"),
                ("estimated_crown_y", Double(crownY)),
            ])
        }

        let geometry = FaceGeometry(faceBox: faceBox,
                                    crownY: crownY,
                                    chinY: max(crownY + 1, chinY),
                                    midlineX: faceBox.midX,
                                    chinFromLandmarks: chinFromLandmarks)

        let spec = IDPhotoSpec.ica
        // Head height as it would land in the 45 mm frame once scaled — this is
        // the number that decides acceptance, so log it next to its inputs.
        Log.stage("face", [
            ("file", label),
            ("faces", faces.count),
            ("box", faceBox),
            ("crown_y", Double(geometry.crownY)),
            ("chin_y", Double(geometry.chinY)),
            ("chin_src", chinFromLandmarks ? "landmarks" : "facebox"),
            ("crown_to_chin_px", Double(geometry.crownToChin)),
            ("target_mm", spec.targetHeadMM),
        ], ms: watch.lap())

        return geometry
    }

    private static func bestLandmarkFace(_ results: [VNFaceObservation]?,
                                         matching face: VNFaceObservation) -> VNFaceObservation? {
        guard let results, !results.isEmpty else { return nil }
        // Landmark and rectangle passes return independent observation lists;
        // pair them by box overlap so a group shot doesn't take another person's chin.
        return results.max { a, b in
            face.boundingBox.intersection(a.boundingBox).area
                < face.boundingBox.intersection(b.boundingBox).area
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
