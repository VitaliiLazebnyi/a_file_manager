internal import Foundation

/// `min <target> FILE OUT [--timeout S]`: makes a failing input smaller while it keeps failing with
/// the same signature (delta debugging, then simpler bytes), for at most four minutes.
@MainActor
internal final class FuzzMinimiser {
    /// The target the input fails in.
    private let target: FuzzTarget
    /// Extra arguments of each `run` (the timeout).
    private var extra: [String] = []
    /// Where each candidate is written.
    private var candidatePath = ""
    /// The log of the last run.
    private var logPath = ""
    /// Runs made.
    private var runs = 0
    /// When to stop.
    private let deadline = Date().addingTimeInterval(240)

    /// Whether the four minutes are up.
    private var isOutOfTime: Bool {
        Date() >= deadline
    }

    /// A minimiser for inputs of `target`.
    internal init(target: FuzzTarget) {
        self.target = target
    }

    /// Minimises, writes the result and exits 0; exits 1 when the input does not fail.
    internal func run(_ arguments: [String]) -> Never {
        guard arguments.count >= 2, let contents = FuzzFiles.read(arguments[0]) else {
            print("min <target> FILE OUT [--timeout S]")
            exit(2)
        }
        var best = [UInt8](contents)
        let outPath = arguments[1]
        if arguments.count > 3, arguments[2] == "--timeout" {
            extra = ["--timeout", arguments[3]]
        }
        candidatePath = outPath + ".try"
        logPath = outPath + ".trylog"
        let wanted = signature(of: best)
        guard !wanted.isEmpty else {
            print("input does not fail")
            exit(1)
        }
        print("signature: \(wanted); \(best.count) bytes")
        var changed = true
        while changed, !isOutOfTime {
            changed = removeChunks(&best, keeping: wanted)
            // Then simplify the bytes that are left.
            if best.count <= 600 {
                simplifyBytes(&best, keeping: wanted)
            }
        }
        FuzzFiles.write(outPath, best)
        try? FileManager.default.removeItem(atPath: candidatePath)
        try? FileManager.default.removeItem(atPath: logPath)
        print("minimised to \(best.count) bytes in \(runs) runs -> \(outPath)")
        exit(0)
    }

    /// The signature `data` fails with, or "" when it passes.
    private func signature(of data: [UInt8]) -> String {
        FuzzFiles.write(candidatePath, data)
        runs += 1
        let status = FuzzFiles.launch(["run", target.name, candidatePath] + extra, log: logPath, environment: [:])
        if status == 0 {
            return ""
        }
        return CrashSignature(log: FuzzFiles.readText(logPath), status: status).text
    }

    /// Removes chunks of halving sizes while the signature stays; true when something was removed.
    private func removeChunks(_ best: inout [UInt8], keeping wanted: String) -> Bool {
        var changed = false
        var chunk = max(1, best.count / 2)
        while chunk >= 1, !isOutOfTime {
            var start = 0
            while start < best.count, !isOutOfTime {
                var candidate = best
                candidate.removeSubrange(start..<min(best.count, start + chunk))
                if candidate.count < best.count, signature(of: candidate) == wanted {
                    best = candidate
                    changed = true
                } else {
                    start += chunk
                }
            }
            if chunk == 1 {
                break
            }
            chunk /= 2
        }
        return changed
    }

    /// Replaces each byte with 0, "0" or "a" where the signature stays.
    private func simplifyBytes(_ best: inout [UInt8], keeping wanted: String) {
        let simple: [UInt8] = [0, 0x30, 0x61]
        for index in best.indices where !simple.contains(best[index]) && !isOutOfTime {
            for replacement in simple {
                var candidate = best
                candidate[index] = replacement
                if signature(of: candidate) == wanted {
                    best = candidate
                    break
                }
            }
        }
    }

    deinit {
        // Nothing to release: the process ends in `run()`.
    }
}
