import CoreGraphics
import Foundation

/// Structured, greppable stage logging to stderr.
///
/// Every line is `cutout stage=<name> key=value ...`, one line per pipeline stage,
/// always with `ms=` at the end. The point is post-mortem: when a crop comes out
/// wrong, the log should say whether the mask or the face box lied, without
/// re-running anything.
///
///     cutout stage=mask file="katie.jpg" instances=1 mask=1024x768 src=4032x3024 upscaled=yes ms=412
///
/// stderr, not stdout, so the CLI harness can pipe image bytes on stdout.
enum Log {
    /// Set to false to silence (used by unit-style harness runs that assert on output).
    nonisolated(unsafe) static var enabled = true

    private static let lock = NSLock()

    static func stage(_ name: String, _ fields: [(String, Any)] = [], ms: Double? = nil) {
        guard enabled else { return }
        var line = "cutout stage=\(name)"
        for (k, v) in fields {
            line += " \(k)=\(format(v))"
        }
        if let ms {
            line += String(format: " ms=%.1f", ms)
        }
        line += "\n"
        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }

    static func warn(_ name: String, _ fields: [(String, Any)] = []) {
        stage("warn:\(name)", fields)
    }

    static func error(_ name: String, _ fields: [(String, Any)] = []) {
        stage("error:\(name)", fields)
    }

    private static func format(_ value: Any) -> String {
        switch value {
        case let s as String:
            // Quote anything that would break `key=value` splitting.
            return s.contains(where: { $0 == " " || $0 == "\"" || $0 == "=" })
                ? "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
                : s
        case let d as Double:
            return String(format: "%.2f", d)
        case let f as CGFloat:
            return String(format: "%.2f", Double(f))
        case let b as Bool:
            return b ? "yes" : "no"
        case let size as CGSize:
            return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        case let rect as CGRect:
            return String(format: "%.0f,%.0f,%.0fx%.0f",
                          rect.origin.x, rect.origin.y, rect.width, rect.height)
        default:
            return "\(value)"
        }
    }
}

/// Wall-clock stopwatch in milliseconds. `Stopwatch()` starts it; `.lap()` reads
/// and resets so consecutive stages each report their own elapsed time.
struct Stopwatch {
    private var start = DispatchTime.now()

    mutating func lap() -> Double {
        let now = DispatchTime.now()
        let ms = Double(now.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
        start = now
        return ms
    }

    func peek() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}
