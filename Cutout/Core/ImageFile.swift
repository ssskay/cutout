import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Loading and writing image files. Everything here is local disk I/O — there is
/// no code path in this app that opens a socket.
enum ImageFile {

    static let readableTypes: [UTType] = [.image]

    static func isReadable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: - Load

    struct Loaded {
        var image: CIImage           // orientation applied, origin at (0,0)
        var pixelSize: CGSize
        var colorSpace: CGColorSpace
        var orientation: CGImagePropertyOrientation
    }

    /// Decodes a file and bakes in its EXIF orientation.
    ///
    /// Orientation is applied up front, once, so that Vision's mask, the face box,
    /// the crown scan and the exported pixels all live in the same coordinate
    /// space. Skipping this is how you get a mask that fits a sideways head.
    static func load(_ url: URL) throws -> Loaded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else {
            throw CutoutError.unreadableImage(url)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up

        var image = CIImage(cgImage: cgImage).oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                        y: -image.extent.minY))

        // Keep a wide-gamut source in its own space; fall back to sRGB for
        // anything exotic (CMYK, indexed) so the output is predictable.
        var space = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        if space.model != .rgb {
            space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }

        return Loaded(image: image,
                      pixelSize: image.extent.size,
                      colorSpace: space,
                      orientation: orientation)
    }

    // MARK: - Write

    /// Writes `image` and returns the URL actually used and the byte count.
    ///
    /// Never overwrites: if the chosen name is taken, `-2`, `-3`, … is appended.
    /// The source file is never a candidate destination — exports always go to
    /// the chosen output folder.
    @discardableResult
    static func write(_ image: CIImage,
                      format: OutputFormat,
                      quality: Double,
                      colorSpace: CGColorSpace,
                      to directory: URL,
                      basename: String,
                      context: CIContext,
                      label: String = "") throws -> (url: URL, bytes: Int) {
        var watch = Stopwatch()
        let url = uniqueURL(in: directory, basename: basename, extension: format.fileExtension)

        // PNG keeps alpha; JPEG has none, so callers must have flattened already.
        let outputSpace = outputColorSpace(for: format, source: colorSpace)

        do {
            switch format {
            case .png:
                try context.writePNGRepresentation(of: image,
                                                   to: url,
                                                   format: .RGBA8,
                                                   colorSpace: outputSpace,
                                                   options: [:])
            case .jpeg:
                try writeJPEG(image,
                              quality: quality,
                              colorSpace: outputSpace,
                              to: url,
                              context: context)
            }
        } catch let error as CutoutError {
            throw error
        } catch {
            throw CutoutError.encodingFailed(error.localizedDescription)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? Int) ?? 0

        Log.stage("write", [
            ("file", label),
            ("out", url.lastPathComponent),
            ("format", format.rawValue),
            ("px", image.extent.size),
            ("bytes", bytes),
            ("quality", format == .jpeg ? quality : 1.0),
            ("chroma", format == .jpeg ? jpegChromaSubsampling(url) : "n/a"),
        ], ms: watch.lap())

        return (url, bytes)
    }

    /// Writes a JPEG through `CGImageDestination` rather than
    /// `CIContext.writeJPEGRepresentation`.
    ///
    /// This is not a stylistic preference — the two encoders disagree about
    /// chroma subsampling. Measured on macOS 15.1, at the same requested quality:
    ///
    ///     quality   writeJPEGRepresentation   CGImageDestination
    ///     0.95      4:2:0                     4:2:0
    ///     1.00      4:2:2                     4:4:4
    ///
    /// ImageIO gives no key that decouples subsampling from quality (several
    /// plausible ones were tried and all silently ignored), so **4:4:4 is only
    /// reachable at quality 1.0, and only through this API**. 4:2:0 averages
    /// colour over 2×2 blocks, which is precisely the artefact that shows up as a
    /// dirty fringe where a subject meets a pure white backdrop — the one place
    /// these exports are always viewed. The larger file is the cheaper mistake.
    private static func writeJPEG(_ image: CIImage,
                                  quality: Double,
                                  colorSpace: CGColorSpace,
                                  to url: URL,
                                  context: CIContext) throws {
        guard let cgImage = context.createCGImage(image,
                                                  from: image.extent,
                                                  format: .RGBA8,
                                                  colorSpace: colorSpace) else {
            throw CutoutError.encodingFailed("could not rasterise the composite")
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CutoutError.encodingFailed("could not create a JPEG destination at \(url.path)")
        }

        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CutoutError.encodingFailed("JPEG encoding failed")
        }
    }

    /// JPEG has no alpha channel and no useful notion of a linear working space,
    /// so writing one always goes out as a plain RGB space. PNG keeps whatever
    /// the source had, which preserves a P3 cutout for later editing.
    private static func outputColorSpace(for format: OutputFormat, source: CGColorSpace) -> CGColorSpace {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard source.model == .rgb else { return srgb }
        return source
    }

    /// Finds a free filename. Checked-then-created is a race in principle; in a
    /// single-user desktop export it is the right trade against the alternative
    /// of clobbering someone's earlier export.
    static func uniqueURL(in directory: URL, basename: String, extension ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(basename).\(ext)")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(basename)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Reads the JPEG's SOF marker and reports the luma sampling factors, e.g.
    /// `4:4:4` or `4:2:0`.
    ///
    /// ImageIO picks subsampling from the quality setting without telling you, and
    /// 4:2:0 visibly smears the coloured edge of a subject against pure white.
    /// Rather than trust that q=0.95 means 4:4:4, the log states what was written.
    static func jpegChromaSubsampling(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "unknown" }
        var i = 2   // skip SOI
        while i + 9 < data.count {
            guard data[i] == 0xFF else { i += 1; continue }
            let marker = data[i + 1]
            // SOF0/1/2 (baseline, extended, progressive) carry the sampling factors.
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                let componentCount = Int(data[i + 9])
                guard componentCount >= 1, i + 10 + componentCount * 3 <= data.count else { return "unknown" }
                let yFactors = data[i + 11]     // first component's H<<4 | V
                let h = Int(yFactors >> 4)
                let v = Int(yFactors & 0x0F)
                if componentCount == 1 { return "grayscale" }
                switch (h, v) {
                case (1, 1): return "4:4:4"
                case (2, 1): return "4:2:2"
                case (2, 2): return "4:2:0"
                case (1, 2): return "4:4:0"
                default: return "h\(h)v\(v)"
                }
            }
            // Standalone markers carry no length field.
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                i += 2
                continue
            }
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard length >= 2 else { return "unknown" }
            i += 2 + length
        }
        return "unknown"
    }
}
