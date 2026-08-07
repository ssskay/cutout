import CoreGraphics
import CoreImage
import Foundation

/// Processes a batch of files. Shared by one-shot runs and the folder watcher so
/// both behave identically.
struct Runner {
    let options: CLI.Options
    let pipeline = Pipeline()

    struct BatchResult {
        var succeeded: [URL] = []
        var failed: [(url: URL, message: String)] = []
        var warnings: Int = 0
    }

    func run(_ inputs: [URL], outputDirectory: URL) -> BatchResult {
        var result = BatchResult()

        do {
            try FileManager.default.createDirectory(at: outputDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            CLI.err("cutout: cannot create output directory \(outputDirectory.path): \(error.localizedDescription)")
            result.failed = inputs.map { ($0, "output directory unavailable") }
            return result
        }

        for input in inputs {
            do {
                try process(input, outputDirectory: outputDirectory, result: &result)
            } catch {
                // One bad file never stops a batch. Twenty listing photos with a
                // corrupt nineteenth should still yield nineteen exports.
                result.failed.append((input, error.localizedDescription))
                Log.error("file", [("file", input.lastPathComponent),
                                   ("message", error.localizedDescription)])
                if options.json {
                    CLI.json(["input": input.path,
                              "ok": false,
                              "error": error.localizedDescription])
                } else {
                    CLI.err("  ✗ \(input.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        return result
    }

    private func process(_ input: URL,
                         outputDirectory: URL,
                         result: inout BatchResult) throws {
        let prepared = try pipeline.prepare(url: input,
                                            refinement: options.settings.refinement,
                                            wantsFace: options.settings.preset.requiresFace)

        if let faceError = prepared.faceError {
            Log.warn("face-unavailable", [("file", prepared.name), ("reason", faceError)])
        }

        if options.dumpMask {
            let base = input.deletingPathExtension().lastPathComponent + "-mask"
            try ImageFile.write(prepared.mask,
                                format: .png,
                                quality: 1.0,
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                to: outputDirectory,
                                basename: base,
                                context: pipeline.context,
                                label: prepared.name)
        }

        if options.sweep {
            try sweep(input, outputDirectory: outputDirectory)
            result.succeeded.append(input)
            return
        }

        let outcome = try pipeline.export(prepared,
                                          settings: options.settings,
                                          adjustment: options.adjustment,
                                          to: outputDirectory)

        result.succeeded.append(input)
        result.warnings += outcome.warnings.isEmpty ? 0 : 1

        for warning in outcome.warnings {
            Log.warn("export", [("file", prepared.name), ("message", warning)])
        }

        if options.json {
            var fields: [String: Any] = [
                "input": input.path,
                "output": outcome.url.path,
                "ok": true,
                "bytes": outcome.bytes,
                "width": Int(outcome.pixelSize.width.rounded()),
                "height": Int(outcome.pixelSize.height.rounded()),
                "preset": options.settings.preset.label,
                "warnings": outcome.warnings,
            ]
            if let headMM = outcome.headMM { fields["head_mm"] = headMM }
            CLI.json(fields)
        } else {
            var line = "  ✓ \(input.lastPathComponent) → \(outcome.url.lastPathComponent)"
            if let headMM = outcome.headMM { line += String(format: "  head=%.1fmm", headMM) }
            CLI.out(line)
            for warning in outcome.warnings {
                CLI.err("    ! \(warning)")
            }
        }
    }

    /// Exports an erode/feather grid. The refinement is baked into the mask, so
    /// each combination genuinely has to redo the Vision pass.
    private func sweep(_ input: URL, outputDirectory: URL) throws {
        for erode in [0.0, 0.5, 1.0, 1.5, 2.0] {
            for feather in [0.0, 0.5, 0.75, 1.0] {
                var settings = options.settings
                settings.refinement = MaskRefinement(erodeRadius: erode, featherRadius: feather)
                let prepared = try pipeline.prepare(url: input,
                                                    refinement: settings.refinement,
                                                    wantsFace: false)
                let (image, _) = try pipeline.render(prepared, settings: settings)
                let tag = String(format: "e%.1f-f%.2f", erode, feather)
                let base = input.deletingPathExtension().lastPathComponent + "-" + tag
                try ImageFile.write(image,
                                    format: settings.preset.format,
                                    quality: settings.jpegQuality,
                                    colorSpace: prepared.colorSpace,
                                    to: outputDirectory,
                                    basename: base,
                                    context: pipeline.context,
                                    label: prepared.name)
            }
        }
    }
}
