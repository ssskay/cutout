import Foundation

enum CutoutError: LocalizedError {
    case unreadableImage(URL)
    case noForeground
    case maskGenerationFailed(String)
    case noFaceDetected
    case headTooSmall(mm: Double)
    case encodingFailed(String)
    case outputFolderUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let url):
            return "Could not decode \(url.lastPathComponent) as an image."
        case .noForeground:
            // Deliberately loud: the alternative — silently exporting the original
            // image — is how you end up shipping an eBay listing with a kitchen
            // counter still in it.
            return "Vision found no subject to lift out of this image. Nothing was exported."
        case .maskGenerationFailed(let detail):
            return "Mask generation failed: \(detail)"
        case .noFaceDetected:
            return "No face found — the ID preset needs one. Use a different preset or photo."
        case .headTooSmall(let mm):
            return String(format: "Detected head height is %.1f mm, outside the 25–35 mm ICA range even after scaling.", mm)
        case .encodingFailed(let detail):
            return "Could not write the image: \(detail)"
        case .outputFolderUnavailable:
            return "The export folder is no longer reachable. Pick it again."
        }
    }
}
