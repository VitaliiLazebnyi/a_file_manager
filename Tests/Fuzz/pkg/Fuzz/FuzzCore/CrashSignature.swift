internal import Foundation

/// What killed a worker, from what it wrote: the kind (property, timeout, memory, signal,
/// AddressSanitizer report, exit status) and the top frame inside the driver's binary.
internal struct CrashSignature {
    /// The kind (such as `timeout` or `asan-heap-buffer-overflow`) and the place: the key findings
    /// are filed by.
    internal let text: String

    /// The signature of a worker that wrote `log` and ended with `status`.
    internal init(log: String, status: Int32) {
        let lines = log.components(separatedBy: "\n")
        if let line = lines.first(where: { $0.hasPrefix("FZ-PROPERTY ") }) {
            text = "property " + line.dropFirst(12)
            return
        }
        let kind: String
        let frames: [String]
        if let line = lines.first(where: { $0.contains("ERROR: AddressSanitizer") }) {
            let report = line.components(separatedBy: "AddressSanitizer: ").last ?? ""
            kind = "asan-" + (report.split(separator: " ").first.map(String.init) ?? "error")
            frames = Self.sanitizerFrames(lines)
        } else {
            kind = Self.kind(of: lines, status: status)
            frames = Self.backtraceFrames(lines)
        }
        // Frames of the fuzzer itself say nothing about the place.
        let own = frames.filter { !$0.contains("8FuzzCore") && !$0.hasPrefix("main") && !$0.contains("FuzzCore.") }
        if kind == "timeout" || kind == "rss" {
            // The interrupted frame is arbitrary; name the outermost project frame below the driver instead.
            let name = own.last.map { $0.components(separatedBy: " + ").first ?? $0 } ?? "?"
            text = kind + " " + name
        } else {
            text = kind + " " + (own.first ?? frames.first ?? "?")
        }
    }

    /// The kind of a death without a sanitizer report: what the watchdog or the crash handler wrote.
    private static func kind(of lines: [String], status: Int32) -> String {
        if lines.contains(where: { $0.hasPrefix("FZ-TIMEOUT") }) {
            return "timeout"
        }
        if lines.contains(where: { $0.hasPrefix("FZ-RSS") }) {
            return "rss"
        }
        if let line = lines.first(where: { $0.hasPrefix("FZ-CRASH") }) {
            return "signal" + (line.split(separator: " ").last.map(String.init) ?? "")
        }
        return "exit\(status)"
    }

    /// The driver's frames of the first stack of an AddressSanitizer report.
    private static func sanitizerFrames(_ lines: [String]) -> [String] {
        var frames: [String] = []
        var started = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#0 ") {
                if started {
                    break
                }
                started = true
            }
            guard started, trimmed.hasPrefix("#"), let range = trimmed.range(of: " in ") else {
                continue
            }
            guard trimmed.contains("(fuzz-") || trimmed.contains(".swift:") else {
                continue
            }
            var frame = String(trimmed[range.upperBound...])
            if let place = frame.range(of: " (") {
                frame = String(frame[..<place.lowerBound])
            }
            frames.append(frame)
        }
        return frames
    }

    /// The driver's frames of the backtrace the crash handler wrote between `FZ-LOAD` and `FZ-END`,
    /// without the handler's own.
    private static func backtraceFrames(_ lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("FZ-LOAD") }) else {
            return []
        }
        var frames: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("FZ-END") {
                break
            }
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, parts[1].hasPrefix("fuzz-") else {
                continue
            }
            let symbol = String(parts[3])
            if !symbol.hasPrefix("on_"), !symbol.hasPrefix("dump "), !symbol.hasPrefix("fz_") {
                frames.append(symbol)
            }
        }
        return frames
    }
}
