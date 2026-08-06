import CoreImage
import Foundation

/// Runs the pipeline off the main thread.
///
/// Concurrency is capped at two rather than left to `activeProcessorCount`:
/// each in-flight image holds a decoded source, a full-resolution mask and a
/// scan buffer, so a batch of twenty 24-megapixel photos would otherwise try to
/// hold several gigabytes at once. Vision's own work runs on the Neural Engine
/// and does not get faster by queueing more of it.
final class ProcessingQueue {
    static let shared = ProcessingQueue()

    private let pipeline = Pipeline()
    private let queue: OperationQueue

    var context: CIContext { pipeline.context }

    init() {
        queue = OperationQueue()
        queue.name = "me.sarakay.cutout.pipeline"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
    }

    func prepare(url: URL,
                 refinement: MaskRefinement,
                 wantsFace: Bool) async throws -> PreparedImage {
        try await run { try self.pipeline.prepare(url: url, refinement: refinement, wantsFace: wantsFace) }
    }

    func render(_ prepared: PreparedImage,
                settings: ExportSettings,
                adjustment: IDAdjustment) async throws -> (image: CIImage, headMM: Double?) {
        try await run { try self.pipeline.render(prepared, settings: settings, adjustment: adjustment) }
    }

    func export(_ prepared: PreparedImage,
                settings: ExportSettings,
                adjustment: IDAdjustment,
                to directory: URL) async throws -> ExportOutcome {
        try await run {
            try self.pipeline.export(prepared, settings: settings, adjustment: adjustment, to: directory)
        }
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
