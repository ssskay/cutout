import CoreImage
import CoreGraphics
import Foundation

// MARK: - Backdrop

/// What goes behind the lifted subject.
enum Backdrop: Equatable, Hashable {
    case transparent
    case white
    case custom(RGBColor)

    var supportsAlpha: Bool { self == .transparent }

    var label: String {
        switch self {
        case .transparent: return "Transparent"
        case .white: return "White"
        case .custom: return "Custom"
        }
    }

    /// The colour to flatten onto when the container format has no alpha (JPEG).
    var flattenedColor: RGBColor {
        switch self {
        case .transparent, .white: return .white
        case .custom(let c): return c
        }
    }
}

/// A plain sRGB colour, `Codable` so the last-used swatch survives a relaunch.
struct RGBColor: Equatable, Hashable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    static let white = RGBColor(red: 1, green: 1, blue: 1)

    var ciColor: CIColor { CIColor(red: red, green: green, blue: blue, alpha: 1) }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                components: [red, green, blue, 1]) ?? CGColor(gray: 1, alpha: 1)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(cgColor: CGColor) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) ?? cgColor
        let c = converted.components ?? [1, 1, 1, 1]
        self.red = c.count > 0 ? Double(c[0]) : 1
        self.green = c.count > 1 ? Double(c[1]) : 1
        self.blue = c.count > 2 ? Double(c[2]) : 1
    }
}

// MARK: - Output format

enum OutputFormat: String, Codable {
    case png
    case jpeg

    var fileExtension: String { self == .png ? "png" : "jpg" }
}

// MARK: - Preset

enum Preset: Hashable, Identifiable, CaseIterable {
    case transparentPNG
    case ebayListing
    case idPhoto
    case custom

    var id: Self { self }

    static var allCases: [Preset] { [.transparentPNG, .ebayListing, .idPhoto, .custom] }

    var label: String {
        switch self {
        case .transparentPNG: return "Transparent PNG"
        case .ebayListing: return "eBay listing"
        case .idPhoto: return "ID photo (ICA)"
        case .custom: return "Custom size"
        }
    }

    var detail: String {
        switch self {
        case .transparentPNG: return "Source resolution, alpha preserved"
        case .ebayListing: return "1600 × 1600 JPEG, white, subject at 90%"
        case .idPhoto: return "400 × 514 JPEG, 35 × 45 mm, 32 mm head"
        case .custom: return "Your size, subject at 90%"
        }
    }

    var format: OutputFormat {
        switch self {
        case .transparentPNG: return .png
        case .ebayListing, .idPhoto, .custom: return .jpeg
        }
    }

    /// Fixed output size, or nil when the preset follows the source / user setting.
    var fixedSize: CGSize? {
        switch self {
        case .transparentPNG: return nil
        case .ebayListing: return CGSize(width: 1600, height: 1600)
        case .idPhoto: return IDPhotoSpec.ica.pixelSize
        case .custom: return nil
        }
    }

    /// Fraction of the frame the subject should occupy — 90%, i.e. 5% padding
    /// on each side. Not used by the ID preset, which positions by head height.
    var subjectFillFraction: Double { 0.90 }

    /// The ID preset is the only one that needs a face; the others work on
    /// anything Vision can lift.
    var requiresFace: Bool { self == .idPhoto }

    /// Suffix appended to the source filename on export.
    var filenameSuffix: String {
        switch self {
        case .transparentPNG: return "-cutout"
        case .ebayListing: return "-ebay"
        case .idPhoto: return "-id"
        case .custom: return "-cutout"
        }
    }
}

// MARK: - ID photo spec

/// Singapore ICA passport/ID photo geometry.
///
/// The spec is in millimetres and the tolerance band is narrow, so everything
/// here converts through a single px-per-mm constant rather than eyeballing
/// pixel offsets. A rejected photo costs a week, so the UI shows the resulting
/// head height in mm and lets it be overridden — none of this is trusted blindly.
struct IDPhotoSpec {
    let widthMM: Double
    let heightMM: Double
    let pixelWidth: Int
    let pixelHeight: Int

    /// Crown-to-chin must land in this band.
    let minHeadMM: Double
    let maxHeadMM: Double
    /// What we aim for — comfortably inside the band in both directions.
    let targetHeadMM: Double
    /// Gap from the top edge of the frame to the crown.
    let headroomMM: Double

    static let ica = IDPhotoSpec(
        widthMM: 35, heightMM: 45,
        pixelWidth: 400, pixelHeight: 514,
        minHeadMM: 25, maxHeadMM: 35,
        targetHeadMM: 32,
        headroomMM: 4
    )

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    var pixelsPerMMVertical: Double { Double(pixelHeight) / heightMM }
    var pixelsPerMMHorizontal: Double { Double(pixelWidth) / widthMM }

    func mm(fromVerticalPixels px: Double) -> Double { px / pixelsPerMMVertical }
    func pixels(fromVerticalMM mm: Double) -> Double { mm * pixelsPerMMVertical }

    func isHeadHeightAcceptable(_ mm: Double) -> Bool {
        mm >= minHeadMM && mm <= maxHeadMM
    }
}

// MARK: - Export settings

struct ExportSettings {
    var preset: Preset = .transparentPNG
    var backdrop: Backdrop = .transparent
    var customSize = CGSize(width: 1200, height: 1200)
    var refinement = MaskRefinement.default

    /// 1.0, not 0.95, and the difference is chroma rather than quantisation:
    /// ImageIO only emits 4:4:4 at 1.0 and drops to 4:2:0 at every lower setting
    /// (see `ImageFile.writeJPEG`). Colour-accurate subject edges against white
    /// matter more here than file size, and at these output dimensions the
    /// penalty is ~0.2 MB for an ID photo and ~1.6 MB for an eBay listing.
    var jpegQuality: Double = 1.0

    /// ID exports above this get a warning; some upload forms reject larger files.
    var fileSizeWarningBytes = 3 * 1024 * 1024

    /// Output pixel size for a given source, resolving the preset's rules.
    func outputSize(sourceSize: CGSize) -> CGSize? {
        switch preset {
        case .transparentPNG: return nil          // keep source resolution
        case .custom: return customSize
        default: return preset.fixedSize
        }
    }

    /// Transparent output only makes sense in a format that has alpha. Choosing
    /// "Transparent" with the eBay preset silently means white, so resolve it here
    /// once instead of at three call sites.
    var effectiveBackdrop: Backdrop {
        preset.format == .png ? backdrop : .init(flattened: backdrop)
    }
}

private extension Backdrop {
    init(flattened backdrop: Backdrop) {
        switch backdrop {
        case .transparent, .white: self = .white
        case .custom(let c): self = .custom(c)
        }
    }
}
