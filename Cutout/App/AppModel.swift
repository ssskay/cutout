import AppKit
import CoreImage
import Foundation
import Observation
import UniformTypeIdentifiers

/// One dropped file and everything the UI knows about it.
@Observable
@MainActor
final class ImageItem: Identifiable {
    enum State: Equatable {
        case pending
        case processing
        case ready
        case failed(String)

        var isTerminal: Bool {
            if case .processing = self { return false }
            if case .pending = self { return false }
            return true
        }
    }

    let id = UUID()
    let url: URL
    var state: State = .pending

    /// Small source thumbnail for the filmstrip.
    var thumbnail: NSImage?
    /// Original image, fitted for the "before" side of the preview.
    var beforePreview: NSImage?
    /// Composited result at current settings, for the "after" side.
    var afterPreview: NSImage?

    /// Head height in millimetres for the ID preset, as currently placed.
    var headMM: Double?
    var adjustment = IDAdjustment.identity
    /// Non-fatal notes from the last export.
    var warnings: [String] = []
    /// Set when the ID preset was requested but no face was found.
    var faceIssue: String?

    /// The expensive Vision output. Held so preset and backdrop changes re-composite
    /// instead of re-running the model.
    var prepared: PreparedImage?
    /// Refinement the cached `prepared` was built with; a change invalidates it.
    var preparedRefinement: MaskRefinement?
    /// Whether the cached `prepared` includes face geometry.
    var preparedWithFace = false

    var name: String { url.lastPathComponent }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    init(url: URL) {
        self.url = url
    }
}

@Observable
@MainActor
final class AppModel {
    var items: [ImageItem] = []
    var selectedID: ImageItem.ID?
    var settings = ExportSettings() {
        didSet { settingsChanged(from: oldValue) }
    }

    var outputFolder: URL?
    var isExporting = false
    var exportCompleted = 0
    var exportTotal = 0
    /// Result banner text after a batch finishes.
    var exportSummary: String?
    var exportFailures: [String] = []

    private let queue = ProcessingQueue.shared
    private var previewGeneration = 0

    var selectedItem: ImageItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    var canExport: Bool {
        !isExporting && items.contains { $0.state == .ready }
    }

    init() {
        outputFolder = OutputFolderStore.restore()
    }

    // MARK: - Intake

    func add(urls: [URL]) {
        let fresh = urls
            .filter { ImageFile.isReadable($0) }
            .filter { url in !items.contains { $0.url == url } }
        guard !fresh.isEmpty else { return }

        let newItems = fresh.map { ImageItem(url: $0) }
        items.append(contentsOf: newItems)
        if selectedID == nil { selectedID = newItems.first?.id }

        for item in newItems {
            Task { await process(item) }
        }
    }

    func remove(_ item: ImageItem) {
        items.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = items.first?.id }
    }

    func removeAll() {
        items.removeAll()
        selectedID = nil
        exportSummary = nil
        exportFailures = []
    }

    // MARK: - Processing

    /// Runs Vision for one item and builds its previews.
    ///
    /// A failure here marks the item failed and stops — it is never allowed to
    /// fall through to exporting the untouched original, which would quietly ship
    /// a listing photo with its background intact.
    func process(_ item: ImageItem) async {
        item.state = .processing
        item.faceIssue = nil

        let refinement = settings.refinement
        let wantsFace = settings.preset.requiresFace

        do {
            let prepared = try await queue.prepare(url: item.url,
                                                   refinement: refinement,
                                                   wantsFace: wantsFace)
            item.prepared = prepared
            item.preparedRefinement = refinement
            item.preparedWithFace = wantsFace
            item.faceIssue = prepared.faceError
            item.state = .ready
            await refreshPreview(for: item)
        } catch {
            item.state = .failed(error.localizedDescription)
            item.prepared = nil
            item.thumbnail = nil
            item.afterPreview = nil
            Log.error("item", [("file", item.name), ("message", error.localizedDescription)])
        }
    }

    /// Re-runs anything invalidated by a settings change. Batch stays responsive
    /// because only the composite is redone unless the mask itself changed.
    private func settingsChanged(from old: ExportSettings) {
        let refinementChanged = old.refinement != settings.refinement
        let needsFaceNow = settings.preset.requiresFace

        for item in items {
            let missingFace = needsFaceNow && !item.preparedWithFace
            if refinementChanged || missingFace {
                Task { await process(item) }
            } else {
                Task { await refreshPreview(for: item) }
            }
        }
    }

    /// Rebuilds the before/after images for one item at the current settings.
    func refreshPreview(for item: ImageItem) async {
        guard let prepared = item.prepared, item.state == .ready else { return }

        previewGeneration += 1
        let generation = previewGeneration

        if item.thumbnail == nil {
            item.thumbnail = NSImage.fitting(prepared.source,
                                             maxDimension: 160,
                                             context: queue.context)
        }

        do {
            let (image, headMM) = try await queue.render(prepared,
                                                         settings: settings,
                                                         adjustment: item.adjustment)
            // A later settings change may have already superseded this render.
            guard generation == previewGeneration || item.afterPreview == nil else { return }

            item.afterPreview = NSImage.fitting(image, maxDimension: 1400, context: queue.context)
            item.beforePreview = NSImage.fitting(prepared.source, maxDimension: 1400, context: queue.context)
            item.headMM = headMM
        } catch {
            item.headMM = nil
            item.faceIssue = error.localizedDescription
        }
    }

    func updateAdjustment(_ adjustment: IDAdjustment, for item: ImageItem) {
        item.adjustment = adjustment
        Task { await refreshPreview(for: item) }
    }

    // MARK: - Output folder

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Where should Cutout write exported images?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder = url
        OutputFolderStore.remember(url)
    }

    // MARK: - Export

    /// Exports every ready item. One failure never stops the batch — with twenty
    /// listing photos in flight, stopping on the first bad one is the worst
    /// possible behaviour.
    func exportAll() async {
        guard !isExporting else { return }
        if outputFolder == nil { chooseOutputFolder() }
        guard let folder = outputFolder else { return }

        let targets = items.filter { $0.state == .ready && $0.prepared != nil }
        guard !targets.isEmpty else { return }

        isExporting = true
        exportCompleted = 0
        exportTotal = targets.count
        exportSummary = nil
        exportFailures = []

        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        var succeeded = 0
        var warned = 0

        for item in targets {
            guard let prepared = item.prepared else { continue }
            item.warnings = []
            do {
                let outcome = try await queue.export(prepared,
                                                     settings: settings,
                                                     adjustment: item.adjustment,
                                                     to: folder)
                item.warnings = outcome.warnings
                item.headMM = outcome.headMM
                succeeded += 1
                if !outcome.warnings.isEmpty { warned += 1 }
            } catch {
                item.state = .failed(error.localizedDescription)
                exportFailures.append("\(item.name): \(error.localizedDescription)")
                Log.error("export", [("file", item.name), ("message", error.localizedDescription)])
            }
            exportCompleted += 1
        }

        isExporting = false
        var summary = "Exported \(succeeded) of \(targets.count) to \(folder.lastPathComponent)."
        if warned > 0 { summary += " \(warned) with warnings." }
        exportSummary = summary
        Log.stage("batch", [("exported", succeeded), ("total", targets.count),
                            ("failed", exportFailures.count), ("warned", warned)])
    }

    func revealOutputFolder() {
        guard let outputFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
    }
}

// MARK: - Output folder persistence

/// Stores the export folder as a security-scoped bookmark. Under the sandbox a
/// plain path would stop working at the next launch.
enum OutputFolderStore {
    private static let key = "outputFolderBookmark"

    static func remember(_ url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            Log.warn("bookmark-save", [("message", error.localizedDescription)])
        }
    }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale { remember(url) }
        return url
    }
}

// MARK: - Preview rendering

extension NSImage {
    /// Renders a CIImage down to a display-sized NSImage, preserving alpha so the
    /// transparency checkerboard shows through.
    static func fitting(_ image: CIImage, maxDimension: CGFloat, context: CIContext) -> NSImage? {
        let extent = image.extent
        guard extent.isRasterisable else { return nil }

        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let scaled = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image

        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
