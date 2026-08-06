import CoreGraphics
import CoreImage
import Foundation

/// Everything expensive about one source image, computed once.
///
/// Vision runs on drop, not on export. Changing the backdrop or preset on a
/// filmstrip of twenty photos then costs a re-composite, not twenty more model
/// passes.
struct PreparedImage {
    let url: URL
    let source: CIImage
    let sourceSize: CGSize
    let colorSpace: CGColorSpace
    let mask: CIImage
    let maskInfo: MaskResult
    /// Tight bounding box of the subject, source pixels, top-left origin.
    let subjectBox: CGRect
    /// Present only when a face was found; the ID preset needs it.
    let face: FaceGeometry?
    /// Why the face is missing, if the caller asked for one.
    let faceError: String?

    var name: String { url.lastPathComponent }
}

struct ExportOutcome {
    let url: URL
    let bytes: Int
    let pixelSize: CGSize
    /// Head height in mm for ID exports, nil otherwise.
    let headMM: Double?
    /// Human-readable cautions that did not stop the export.
    var warnings: [String]
}

/// The whole local pipeline: load → mask → refine → place → composite → write.
struct Pipeline {
    let engine: CutoutEngine

    init(engine: CutoutEngine = CutoutEngine()) {
        self.engine = engine
    }

    var context: CIContext { engine.context }

    // MARK: - Prepare

    /// Runs the expensive, settings-independent half: decode, mask, subject box,
    /// and face geometry.
    ///
    /// `wantsFace` is passed rather than inferred so that switching to the ID
    /// preset later can re-prepare only what it needs.
    func prepare(url: URL, refinement: MaskRefinement, wantsFace: Bool) throws -> PreparedImage {
        var watch = Stopwatch()
        let label = url.lastPathComponent

        let loaded = try ImageFile.load(url)
        Log.stage("load", [
            ("file", label),
            ("px", loaded.pixelSize),
            ("orientation", loaded.orientation.rawValue),
            ("colorspace", (loaded.colorSpace.name as String?) ?? "device-rgb"),
        ], ms: watch.lap())

        let maskResult = try engine.generateMask(for: loaded.image,
                                                 refinement: refinement,
                                                 label: label)

        guard let (subjectBox, bitmap) = engine.subjectBoundingBox(mask: maskResult.mask) else {
            // A mask that rasterises to nothing is the same failure as no
            // foreground at all, and gets the same loud treatment.
            Log.error("empty-mask", [("file", label)])
            throw CutoutError.noForeground
        }

        let coverage = bitmap.coverage()
        Log.stage("subject", [
            ("file", label),
            ("box", subjectBox),
            ("coverage", coverage),
        ], ms: watch.lap())

        var face: FaceGeometry?
        var faceError: String?
        if wantsFace {
            do {
                face = try FaceFinder.locate(in: loaded.image, mask: bitmap, label: label)
            } catch {
                faceError = error.localizedDescription
            }
        }

        return PreparedImage(url: url,
                             source: loaded.image,
                             sourceSize: loaded.pixelSize,
                             colorSpace: loaded.colorSpace,
                             mask: maskResult.mask,
                             maskInfo: maskResult,
                             subjectBox: subjectBox,
                             face: face,
                             faceError: faceError)
    }

    // MARK: - Render

    /// The composited result at final output geometry, ready to display or write.
    func render(_ prepared: PreparedImage,
                settings: ExportSettings,
                adjustment: IDAdjustment = .identity) throws -> (image: CIImage, headMM: Double?) {
        let backdrop = settings.effectiveBackdrop
        let cutout = engine.composite(source: prepared.source,
                                      mask: prepared.mask,
                                      backdrop: .transparent)

        switch settings.preset {
        case .transparentPNG:
            // Source resolution, no reframing — the whole point of this preset is
            // that the pixels are untouched apart from the alpha.
            let flattened = backdrop == .transparent
                ? cutout
                : engine.composite(source: prepared.source, mask: prepared.mask, backdrop: backdrop)
            return (flattened, nil)

        case .ebayListing, .custom:
            guard let outputSize = settings.outputSize(sourceSize: prepared.sourceSize) else {
                return (cutout, nil)
            }
            let placement = Framing.centreSubject(subjectBox: prepared.subjectBox,
                                                  sourceSize: prepared.sourceSize,
                                                  outputSize: outputSize,
                                                  fillFraction: settings.preset.subjectFillFraction)
            let framed = Framing.render(image: cutout,
                                        placement: placement,
                                        background: backdrop,
                                        context: context)
            return (framed, nil)

        case .idPhoto:
            guard let face = prepared.face else {
                throw CutoutError.noFaceDetected
            }
            let spec = IDPhotoSpec.ica
            let placement = Framing.idPhoto(face: face,
                                            sourceSize: prepared.sourceSize,
                                            spec: spec,
                                            adjustment: adjustment)
            let framed = Framing.render(image: cutout,
                                        placement: placement,
                                        background: backdrop,
                                        context: context)
            let headMM = Framing.headHeightMM(face: face, placement: placement, spec: spec)
            return (framed, headMM)
        }
    }

    // MARK: - Export

    func export(_ prepared: PreparedImage,
                settings: ExportSettings,
                adjustment: IDAdjustment = .identity,
                to directory: URL) throws -> ExportOutcome {
        var watch = Stopwatch()
        let label = prepared.name
        var warnings: [String] = []

        let (image, headMM) = try render(prepared, settings: settings, adjustment: adjustment)
        Log.stage("composite", [
            ("file", label),
            ("preset", settings.preset.label),
            ("backdrop", settings.effectiveBackdrop.label),
            ("px", image.extent.size),
        ], ms: watch.lap())

        if let headMM {
            let spec = IDPhotoSpec.ica
            if !spec.isHeadHeightAcceptable(headMM) {
                warnings.append(String(
                    format: "Head height is %.1f mm — ICA requires %.0f–%.0f mm.",
                    headMM, spec.minHeadMM, spec.maxHeadMM))
                Log.warn("head-out-of-range", [
                    ("file", label), ("mm", headMM),
                    ("min", spec.minHeadMM), ("max", spec.maxHeadMM),
                ])
            }
        }

        let basename = prepared.url.deletingPathExtension().lastPathComponent
            + settings.preset.filenameSuffix

        let written = try ImageFile.write(image,
                                          format: settings.preset.format,
                                          quality: settings.jpegQuality,
                                          colorSpace: prepared.colorSpace,
                                          to: directory,
                                          basename: basename,
                                          context: context,
                                          label: label)

        // Verify rather than trust: ImageIO silently downgrades to 4:2:0 at any
        // quality below 1.0, and a future tweak to the quality slider would
        // otherwise reintroduce colour-smeared edges with no visible signal.
        if settings.preset.format == .jpeg {
            let chroma = ImageFile.jpegChromaSubsampling(written.url)
            if chroma != "4:4:4" {
                warnings.append("JPEG was written as \(chroma) chroma, not 4:4:4 — lower the quality setting less, or edges against white may smear.")
                Log.warn("chroma-subsampled", [("file", label), ("chroma", chroma),
                                               ("quality", settings.jpegQuality)])
            }
        }

        if written.bytes > settings.fileSizeWarningBytes {
            let mb = Double(written.bytes) / (1024 * 1024)
            warnings.append(String(format: "File is %.1f MB, over the 3 MB limit some upload forms enforce.", mb))
            Log.warn("file-too-large", [("file", label), ("bytes", written.bytes)])
        }

        Log.stage("done", [
            ("file", label),
            ("out", written.url.lastPathComponent),
            ("warnings", warnings.count),
        ])

        return ExportOutcome(url: written.url,
                             bytes: written.bytes,
                             pixelSize: image.extent.size,
                             headMM: headMM,
                             warnings: warnings)
    }
}
