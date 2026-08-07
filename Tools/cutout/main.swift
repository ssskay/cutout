import Foundation

// Entry point for the `cutout` CLI. Everything of substance lives in CLI.swift,
// Runner.swift and Watcher.swift; this file only wires them together.

let options: CLI.Options
do {
    options = try CLI.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLI.ParseError {
    CLI.err("cutout: \(error.message)")
    exit(2)
} catch {
    CLI.err("cutout: \(error.localizedDescription)")
    exit(2)
}

Log.enabled = !options.quiet

let home = FileManager.default.homeDirectoryForCurrentUser

switch options.mode {
case .watch:
    let inbox = options.inbox ?? home.appendingPathComponent("Cutout/In")
    let outbox = options.outputDirectory ?? home.appendingPathComponent("Cutout/Out")
    Watcher(options: options, inbox: inbox, outbox: outbox).run()

case .process:
    let outbox = options.outputDirectory ?? URL(fileURLWithPath: "cutout-out")
    let result = Runner(options: options).run(options.inputs, outputDirectory: outbox)

    if !options.json {
        var summary = "cutout: \(result.succeeded.count) of \(options.inputs.count) → \(outbox.path)"
        if result.warnings > 0 { summary += "  (\(result.warnings) with warnings)" }
        CLI.err(summary)
    }

    // Non-zero when anything failed, so a shell caller can branch on it.
    exit(result.failed.isEmpty ? 0 : 1)
}
