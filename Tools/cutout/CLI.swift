import CoreGraphics
import Foundation

/// Command-line surface over the same `Cutout/Core/*.swift` the app uses.
///
/// Compiled from the app's own source files rather than a copy, so the CLI can
/// never drift into testing or shipping a stale engine.
enum CLI {
    static let version = "1.0.0"

    // MARK: - Usage

    static let usage = """
    cutout \(version) — remove image backgrounds locally. No network, ever.

    USAGE
      cutout [options] <image>...        Process files and exit
      cutout watch [options]             Watch a folder and process what lands in it

    PRESETS
      -p, --preset <name>    transparent | ebay | id | custom   (default: ebay)
          --size <WxH>       Output size for --preset custom     (default: 1200x1200)
      -b, --backdrop <c>     transparent | white | #RRGGBB
                             (default: follows the preset)

    OUTPUT
      -o, --out <dir>        Output directory (default: ./cutout-out,
                             or ~/Cutout/Out in watch mode)
          --quality <0..1>   JPEG quality (default: 1.0 — the only setting
                             ImageIO writes as 4:4:4 chroma)

    WATCH MODE
          --in <dir>         Folder to watch (default: ~/Cutout/In)
          --interval <sec>   Poll interval (default: 2)
          --keep             Leave originals in place instead of moving them
                             to <in>/_processed after a successful run
          --no-notify        Do not post a notification when a batch finishes

    ID PRESET
          --id-scale <f>     Multiply the automatic scale  (default: 1.0)
          --id-dx <px>       Nudge right
          --id-dy <px>       Nudge down

    TUNING / DIAGNOSTICS
          --erode <px>       Mask erode radius              (default: 1.0)
          --feather <px>     Mask blur after erode          (default: 0.75)
          --dump-mask        Also write <name>-mask.png
          --sweep            Export an erode/feather grid for comparison, then exit
          --json             Emit one JSON object per file on stdout
      -q, --quiet            Suppress the per-stage log lines on stderr
      -h, --help             This text
          --version          Print the version and exit

    Structured `cutout stage=...` lines go to stderr; results go to stdout, so
    `cutout … --json 2>/dev/null` is safe to pipe.
    """

    // MARK: - Options

    struct Options {
        var mode: Mode = .process
        var inputs: [URL] = []
        var outputDirectory: URL?
        var inbox: URL?
        var settings = ExportSettings()
        var adjustment = IDAdjustment.identity
        var dumpMask = false
        var sweep = false
        var json = false
        var quiet = false
        var moveProcessed = true
        var notify = true
        var pollInterval: TimeInterval = 2
        /// True when --backdrop was given, so the preset default does not override it.
        var backdropExplicit = false

        enum Mode { case process, watch }
    }

    // MARK: - Parsing

    /// Thrown for anything the user can fix by re-typing the command.
    struct ParseError: Error { let message: String }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        // eBay is the default because the automation surfaces exist for listing
        // photos; `cutout photo.jpg` with no flags should do the common thing.
        options.settings.preset = .ebayListing

        var args = arguments
        if args.first == "watch" {
            options.mode = .watch
            args.removeFirst()
        }

        var index = 0
        func next(_ flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw ParseError(message: "missing value for \(flag)") }
            return args[index]
        }
        func number(_ flag: String) throws -> Double {
            let raw = try next(flag)
            guard let value = Double(raw) else {
                throw ParseError(message: "\(flag) expects a number, got '\(raw)'")
            }
            return value
        }

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                print(usage)
                exit(0)
            case "--version":
                print(version)
                exit(0)
            case "-o", "--out":
                options.outputDirectory = URL(fileURLWithPath: (try next(arg) as NSString).expandingTildeInPath)
            case "--in":
                options.inbox = URL(fileURLWithPath: (try next(arg) as NSString).expandingTildeInPath)
            case "-p", "--preset":
                let raw = try next(arg)
                switch raw.lowercased() {
                case "transparent", "png": options.settings.preset = .transparentPNG
                case "ebay": options.settings.preset = .ebayListing
                case "id", "ica": options.settings.preset = .idPhoto
                case "custom": options.settings.preset = .custom
                default: throw ParseError(message: "unknown preset '\(raw)' (transparent|ebay|id|custom)")
                }
            case "--size":
                let raw = try next(arg)
                let parts = raw.lowercased().split(separator: "x")
                guard parts.count == 2,
                      let w = Double(parts[0]), let h = Double(parts[1]),
                      w >= 1, h >= 1 else {
                    throw ParseError(message: "--size expects WxH, got '\(raw)'")
                }
                options.settings.customSize = CGSize(width: w, height: h)
            case "-b", "--backdrop":
                let raw = try next(arg)
                guard let backdrop = parseBackdrop(raw) else {
                    throw ParseError(message: "unknown backdrop '\(raw)' (transparent|white|#RRGGBB)")
                }
                options.settings.backdrop = backdrop
                options.backdropExplicit = true
            case "--erode": options.settings.refinement.erodeRadius = try number(arg)
            case "--feather": options.settings.refinement.featherRadius = try number(arg)
            case "--quality": options.settings.jpegQuality = try number(arg)
            case "--id-scale": options.adjustment.scale = try number(arg)
            case "--id-dx": options.adjustment.offsetX = try number(arg)
            case "--id-dy": options.adjustment.offsetY = try number(arg)
            case "--interval": options.pollInterval = max(0.5, try number(arg))
            case "--keep": options.moveProcessed = false
            case "--no-notify": options.notify = false
            case "--dump-mask": options.dumpMask = true
            case "--sweep": options.sweep = true
            case "--json": options.json = true
            case "-q", "--quiet": options.quiet = true
            default:
                if arg.hasPrefix("-") {
                    throw ParseError(message: "unknown option '\(arg)' (see --help)")
                }
                options.inputs.append(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
            }
            index += 1
        }

        // Transparent output only means anything in a format that carries alpha,
        // so let the PNG preset default to it rather than silently flattening.
        if !options.backdropExplicit {
            options.settings.backdrop = options.settings.preset.format == .png ? .transparent : .white
        }

        switch options.mode {
        case .process:
            guard !options.inputs.isEmpty else {
                throw ParseError(message: "no input files (see --help)")
            }
        case .watch:
            guard options.inputs.isEmpty else {
                throw ParseError(message: "watch mode takes --in <dir>, not file arguments")
            }
        }

        return options
    }

    static func parseBackdrop(_ raw: String) -> Backdrop? {
        switch raw.lowercased() {
        case "transparent", "none", "clear": return .transparent
        case "white": return .white
        default: break
        }
        var hex = raw
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return .custom(RGBColor(red: Double((value >> 16) & 0xFF) / 255,
                                green: Double((value >> 8) & 0xFF) / 255,
                                blue: Double(value & 0xFF) / 255))
    }

    // MARK: - Output helpers

    static func out(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func err(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// One JSON object per line — stable enough to pipe into `jq`.
    static func json(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        out(text)
    }

    /// Posts a Notification Centre banner. Best-effort: a failure here must never
    /// take down a watch daemon that is otherwise working.
    static func notify(title: String, body: String) {
        let script = """
        display notification \(quoteForAppleScript(body)) with title \(quoteForAppleScript(title))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func quoteForAppleScript(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
