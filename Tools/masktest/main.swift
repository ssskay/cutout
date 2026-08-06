import CoreGraphics
import CoreImage
import Foundation

// masktest — a thin CLI over the same Core/ files the app uses.
//
// This exists because mask quality is the thing that decides whether Cutout is
// usable at all, and judging it through a GUI is slow and unrepeatable. Here you
// can sweep erode/feather values over a hair-heavy photo, dump the raw mask, and
// read the same structured log lines the app emits.
//
// Build: scripts/masktest.sh   (then ./build/masktest --help)

func usage() -> Never {
    let text = """
    masktest — Cutout's engine, without the window.

    USAGE
      masktest <image> [<image>...] [options]

    OPTIONS
      -o, --out <dir>        Output directory (default: ./masktest-out)
      -p, --preset <name>    transparent | ebay | id | custom   (default: transparent)
      --size <WxH>           Output size for --preset custom     (default: 1200x1200)
      -b, --backdrop <c>     transparent | white | #RRGGBB       (default: transparent)
      --erode <px>           Mask erode radius                   (default: 1.0)
      --feather <px>         Mask blur radius after erode        (default: 0.75)
      --quality <0..1>       JPEG quality                        (default: 0.95)
      --id-scale <f>         ID preset: multiply the auto scale  (default: 1.0)
      --id-dx <px>           ID preset: nudge right              (default: 0)
      --id-dy <px>           ID preset: nudge down               (default: 0)
      --dump-mask            Also write <name>-mask.png
      --sweep                Export erode/feather combinations for side-by-side
                             comparison and exit
      -h, --help             This text

    Every stage prints a `cutout stage=...` line to stderr.
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

// MARK: - Argument parsing

var inputs: [URL] = []
var outDir = URL(fileURLWithPath: "masktest-out")
var settings = ExportSettings()
var adjustment = IDAdjustment.identity
var dumpMask = false
var sweep = false

func parseColor(_ s: String) -> Backdrop? {
    switch s.lowercased() {
    case "transparent", "none", "clear": return .transparent
    case "white": return .white
    default: break
    }
    var hex = s
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    return .custom(RGBColor(red: Double((value >> 16) & 0xFF) / 255,
                            green: Double((value >> 8) & 0xFF) / 255,
                            blue: Double(value & 0xFF) / 255))
}

var args = Array(CommandLine.arguments.dropFirst())
var index = 0
func next(_ flag: String) -> String {
    index += 1
    guard index < args.count else {
        FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8))
        exit(2)
    }
    return args[index]
}

while index < args.count {
    let arg = args[index]
    switch arg {
    case "-h", "--help": usage()
    case "-o", "--out": outDir = URL(fileURLWithPath: next(arg))
    case "-p", "--preset":
        switch next(arg).lowercased() {
        case "transparent", "png": settings.preset = .transparentPNG
        case "ebay": settings.preset = .ebayListing
        case "id", "ica": settings.preset = .idPhoto
        case "custom": settings.preset = .custom
        default: usage()
        }
    case "--size":
        let parts = next(arg).lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { usage() }
        settings.customSize = CGSize(width: w, height: h)
    case "-b", "--backdrop":
        guard let backdrop = parseColor(next(arg)) else { usage() }
        settings.backdrop = backdrop
    case "--erode": settings.refinement.erodeRadius = Double(next(arg)) ?? 1.0
    case "--feather": settings.refinement.featherRadius = Double(next(arg)) ?? 0.75
    case "--quality": settings.jpegQuality = Double(next(arg)) ?? 0.95
    case "--id-scale": adjustment.scale = Double(next(arg)) ?? 1.0
    case "--id-dx": adjustment.offsetX = Double(next(arg)) ?? 0
    case "--id-dy": adjustment.offsetY = Double(next(arg)) ?? 0
    case "--dump-mask": dumpMask = true
    case "--sweep": sweep = true
    default:
        if arg.hasPrefix("-") { usage() }
        inputs.append(URL(fileURLWithPath: arg))
    }
    index += 1
}

guard !inputs.isEmpty else { usage() }

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let pipeline = Pipeline()
var failures = 0

// MARK: - Run

for input in inputs {
    do {
        let prepared = try pipeline.prepare(url: input,
                                            refinement: settings.refinement,
                                            wantsFace: settings.preset.requiresFace)

        if let faceError = prepared.faceError {
            Log.warn("face-unavailable", [("file", prepared.name), ("reason", faceError)])
        }

        if dumpMask {
            let base = input.deletingPathExtension().lastPathComponent + "-mask"
            try ImageFile.write(prepared.mask,
                                format: .png,
                                quality: 1.0,
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                to: outDir,
                                basename: base,
                                context: pipeline.context,
                                label: prepared.name)
        }

        if sweep {
            // Re-prepare per combination: the refinement is baked into the mask,
            // so a sweep genuinely has to redo the Vision pass each time.
            for erode in [0.0, 0.5, 1.0, 1.5, 2.0] {
                for feather in [0.0, 0.5, 0.75, 1.0] {
                    var sweepSettings = settings
                    sweepSettings.refinement = MaskRefinement(erodeRadius: erode, featherRadius: feather)
                    let swept = try pipeline.prepare(url: input,
                                                     refinement: sweepSettings.refinement,
                                                     wantsFace: false)
                    let (image, _) = try pipeline.render(swept, settings: sweepSettings)
                    let tag = String(format: "e%.1f-f%.2f", erode, feather)
                    let base = input.deletingPathExtension().lastPathComponent + "-" + tag
                    try ImageFile.write(image,
                                        format: sweepSettings.preset.format,
                                        quality: sweepSettings.jpegQuality,
                                        colorSpace: swept.colorSpace,
                                        to: outDir,
                                        basename: base,
                                        context: pipeline.context,
                                        label: swept.name)
                }
            }
            continue
        }

        let outcome = try pipeline.export(prepared,
                                          settings: settings,
                                          adjustment: adjustment,
                                          to: outDir)
        for warning in outcome.warnings {
            Log.warn("export", [("file", prepared.name), ("message", warning)])
        }
        if let headMM = outcome.headMM {
            print(String(format: "%@ → %@  head=%.1fmm",
                         input.lastPathComponent, outcome.url.lastPathComponent, headMM))
        } else {
            print("\(input.lastPathComponent) → \(outcome.url.lastPathComponent)")
        }
    } catch {
        failures += 1
        Log.error("file", [("file", input.lastPathComponent),
                           ("message", error.localizedDescription)])
    }
}

exit(failures == 0 ? 0 : 1)
