import Foundation

/// Watches a folder and processes whatever lands in it.
///
/// Polls rather than using FSEvents on purpose. The hard part of a watch folder
/// is not *noticing* a file, it is knowing the file has finished arriving —
/// AirDrop, a Finder copy and a Photos export all create the file first and fill
/// it in afterwards, so an FSEvent fires while the image is still a truncated
/// half-download. Polling for a size that has stopped changing solves the real
/// problem, and at a two-second interval the latency is irrelevant for a folder
/// a human drops photos into.
struct Watcher {
    let options: CLI.Options
    let inbox: URL
    let outbox: URL

    /// How long a file's size must hold steady before it is considered settled.
    private let stableFor: TimeInterval = 1.5

    /// How long a settled-but-still-incomplete file is given before it is filed
    /// as failed. A stalled transfer deserves patience; a truncated file that
    /// will never be finished should not sit in the inbox forever, silently
    /// re-checked every two seconds until someone notices.
    private let incompleteTimeout: TimeInterval = 300

    private struct Seen {
        var size: Int
        var stableSince: Date
    }

    func run() -> Never {
        let fm = FileManager.default
        for directory in [inbox, outbox] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let runner = Runner(options: options)
        var seen: [URL: Seen] = [:]

        Log.stage("watch-start", [
            ("in", inbox.path),
            ("out", outbox.path),
            ("preset", options.settings.preset.label),
            ("interval", options.pollInterval),
            ("move_processed", options.moveProcessed),
        ])
        CLI.err("cutout: watching \(inbox.path) → \(outbox.path)  [\(options.settings.preset.label)]")

        installSignalHandlers()

        while true {
            var abandoned: [URL] = []
            let ready = scan(&seen, abandoned: &abandoned)

            for url in abandoned {
                let note = (url: url, message: "File stopped arriving before it was complete — the copy or AirDrop was interrupted. Re-send it.")
                Log.error("incomplete-abandoned", [("file", url.lastPathComponent)])
                CLI.err("  ✗ \(url.lastPathComponent): incomplete transfer, giving up")
                move(url, into: inbox.appendingPathComponent("_failed"))
                writeFailureNote(note, in: inbox.appendingPathComponent("_failed"))
                seen.removeValue(forKey: url)
            }

            if !ready.isEmpty {
                let result = runner.run(ready, outputDirectory: outbox)

                for url in result.succeeded where options.moveProcessed {
                    move(url, into: inbox.appendingPathComponent("_processed"))
                }
                for failure in result.failed {
                    move(failure.url, into: inbox.appendingPathComponent("_failed"))
                    writeFailureNote(failure, in: inbox.appendingPathComponent("_failed"))
                }

                // Forget everything handled so a re-dropped file is picked up again.
                for url in ready { seen.removeValue(forKey: url) }

                Log.stage("watch-batch", [
                    ("exported", result.succeeded.count),
                    ("failed", result.failed.count),
                    ("warned", result.warnings),
                ])

                if options.notify {
                    postNotification(for: result)
                }
            }

            Thread.sleep(forTimeInterval: options.pollInterval)
        }
    }

    // MARK: - Scanning

    /// Returns files that have finished arriving since the last poll, and files
    /// that stopped arriving mid-transfer and have run out of patience.
    private func scan(_ seen: inout [URL: Seen], abandoned: inout [URL]) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var ready: [URL] = []
        let now = Date()
        var present = Set<URL>()

        for url in entries {
            guard ImageFile.isReadable(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            present.insert(url)

            if let previous = seen[url] {
                if previous.size == size {
                    // Both gates must pass. A steady size says the writer has
                    // stopped; a complete decode says it stopped because it
                    // *finished* rather than because it stalled. Size alone
                    // exports the top third of a stalled AirDrop as if it were a
                    // real photo.
                    if now.timeIntervalSince(previous.stableSince) >= stableFor {
                        if ImageFile.isComplete(url) {
                            ready.append(url)
                        } else if now.timeIntervalSince(previous.stableSince) >= incompleteTimeout {
                            abandoned.append(url)
                        }
                    }
                } else {
                    // Still growing — reset the clock.
                    seen[url] = Seen(size: size, stableSince: now)
                }
            } else {
                seen[url] = Seen(size: size, stableSince: now)
            }
        }

        // Drop entries for files that vanished, so the map cannot grow forever
        // in a long-running agent.
        for url in seen.keys where !present.contains(url) {
            seen.removeValue(forKey: url)
        }

        return ready.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Filing

    /// Moves an original out of the inbox without ever overwriting.
    private func move(_ url: URL, into directory: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = ImageFile.uniqueURL(
                in: directory,
                basename: url.deletingPathExtension().lastPathComponent,
                extension: url.pathExtension)
            try fm.moveItem(at: url, to: destination)
        } catch {
            Log.warn("move-failed", [("file", url.lastPathComponent),
                                     ("message", error.localizedDescription)])
        }
    }

    /// Leaves the reason next to the file that failed, so the folder explains
    /// itself without anyone having to go read a daemon log.
    private func writeFailureNote(_ failure: (url: URL, message: String), in directory: URL) {
        let note = directory
            .appendingPathComponent(failure.url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("txt")
        let text = "\(failure.url.lastPathComponent)\n\(failure.message)\n"
        try? text.write(to: note, atomically: true, encoding: .utf8)
    }

    // MARK: - Notification

    private func postNotification(for result: Runner.BatchResult) {
        let exported = result.succeeded.count
        let failed = result.failed.count
        guard exported > 0 || failed > 0 else { return }

        var body = "\(exported) image\(exported == 1 ? "" : "s") → \(outbox.lastPathComponent)"
        if failed > 0 { body += ", \(failed) failed" }
        if result.warnings > 0 { body += ", \(result.warnings) with warnings" }

        CLI.notify(title: "Cutout", body: body)
    }

    // MARK: - Signals

    /// `launchctl` stops an agent with SIGTERM. Exit cleanly so a stop during a
    /// batch does not look like a crash in the log.
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Log.stage("watch-stop", [("signal", signalNumber)])
                exit(0)
            }
            source.resume()
            // Held for the process lifetime; cancelling would drop the handler.
            Self.signalSources.append(source)
        }
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
}
