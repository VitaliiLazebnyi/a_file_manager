import Foundation
import TestSupport

/// Runs the benchmarks and holds them to their limits.
///
/// Each run of a benchmark is a process of its own (`Benchmarks measure <name>`), so that the
/// highest footprint of the process is that benchmark's and nothing another one left behind
/// counts. A benchmark runs several times; the median of the runs is compared with the limit.
///
///     Benchmarks [--runs N] [--only a,b] [--record] [--limits path]
///     Benchmarks measure <name>      one run, printed as JSON (what the runs above start)
///     Benchmarks list                the names and what each measures
@MainActor
internal enum Runner {
    /// What a run of the whole set was asked to do.
    private struct Options {
        /// Runs per benchmark.
        var runs = 5
        /// The benchmarks to run; all when empty.
        var only: Set<String> = []
        /// Writes new limits from the measurements instead of comparing with the old ones.
        var record = false
        /// The file of limits.
        var limits = URL(fileURLWithPath: "Tests/Benchmarks/limits.json")
    }

    /// Runs as the arguments say and returns the exit status.
    internal static func main(_ arguments: [String]) -> Int32 {
        do {
            switch arguments.dropFirst().first {
            case "measure":
                return try measure(arguments.dropFirst(2).first ?? "")

            case "list":
                for benchmark in Catalogue.all {
                    print(benchmark.name.padding(toLength: 22, withPad: " ", startingAt: 0), benchmark.summary)
                }
                return 0

            default:
                return try runAll(options(Array(arguments.dropFirst())))
            }
        } catch {
            FileHandle.standardError.write(Data("benchmarks: \(error)\n".utf8))
            return 2
        }
    }

    /// The options of a run of the whole set.
    private static func options(_ arguments: [String]) throws -> Options {
        var options = Options()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--record":
                options.record = true

            case "--runs":
                options.runs = max(1, Int(rest.popFirst() ?? "") ?? options.runs)

            case "--only":
                options.only = Set((rest.popFirst() ?? "").split(separator: ",").map(String.init))

            case "--limits":
                options.limits = URL(fileURLWithPath: rest.popFirst() ?? "")

            default:
                throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "unknown: \(argument)"])
            }
        }
        return options
    }

    /// One run of one benchmark in this process, printed as one line of JSON.
    private static func measure(_ name: String) throws -> Int32 {
        guard let benchmark = Catalogue.all.first(where: { $0.name == name }) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "no benchmark \(name)"])
        }
        let work = try benchmark.prepare()
        let (wallStart, cpuStart) = (DispatchTime.now().uptimeNanoseconds, processorTime())
        try work()
        let (wallEnd, cpuEnd) = (DispatchTime.now().uptimeNanoseconds, processorTime())
        let measurement = Measurement(
            wallSeconds: Double(wallEnd - wallStart) / 1e9,
            cpuSeconds: cpuEnd - cpuStart,
            peakMegabytes: Double(Footprint.peak) / 1_048_576
        )
        print(String(bytes: try JSONEncoder().encode(measurement), encoding: .utf8) ?? "")
        return 0
    }

    /// Seconds of processor time the process has used, all threads together.
    private static func processorTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (time: timeval) in Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// One run of a benchmark in a process of its own.
    private static func runOnce(_ name: String) throws -> Measurement {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["measure", name]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSDebugDescriptionErrorKey: "\(name) failed"])
        }
        return try JSONDecoder().decode(Measurement.self, from: data)
    }

    /// Whether the machine is quiet enough to measure.
    ///
    /// On a machine busy with other work the times say nothing about the code. Prints the
    /// machine and its load either way.
    private static func isQuiet(_ machine: String, runs: Int) -> Bool {
        var load = [0.0]
        _ = getloadavg(&load, 1)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        print(String(format: "machine: %@; load %.1f; %d runs each, medians", machine, load[0], runs))
        guard load[0] <= Double(cores) / 2 else {
            print(
                String(format: "FAIL the machine is busy (load %.1f, %d cores): run again when quiet", load[0], cores)
            )
            return false
        }
        return true
    }

    /// The median of the runs of one benchmark.
    ///
    /// Over its limit, it is measured once more and the lower figures are kept: a machine that
    /// was busy for a moment passes the second time, a real slowdown is over both times.
    private static func median(of name: String, runs: Int, limit: Measurement?) throws -> Measurement {
        let median = Measurement.median(try (0..<runs).map { _ in try runOnce(name) })
        guard let limit, !median.excesses(over: limit).isEmpty else {
            return median
        }
        return median.lower(Measurement.median(try (0..<runs).map { _ in try runOnce(name) }))
    }

    /// Runs the chosen benchmarks and prints the medians.
    ///
    /// The medians are compared with the limits (or recorded as new limits). The exit status is
    /// 1 when a limit was exceeded or is missing, 3 when the machine was too busy to measure (such
    /// a run neither passes nor records).
    private static func runAll(_ options: Options) throws -> Int32 {
        var limits = try Limits.read(from: options.limits)
        let machine = Machine.current
        var recorded = limits.machines[machine] ?? [:]
        var failures: [String] = []
        guard isQuiet(machine, runs: options.runs) else {
            return 3
        }
        for benchmark in Catalogue.all where options.only.isEmpty || options.only.contains(benchmark.name) {
            let limit = options.record ? nil : recorded[benchmark.name]
            let median = try median(of: benchmark.name, runs: options.runs, limit: limit)
            var line = String(
                format: "%@ %8.3f s  %8.3f s cpu  %7.0f MB",
                benchmark.name.padding(toLength: 22, withPad: " ", startingAt: 0),
                median.wallSeconds,
                median.cpuSeconds,
                median.peakMegabytes
            )
            if options.record {
                recorded[benchmark.name] = median.limit()
            } else if let limit {
                let excesses = median.excesses(over: limit)
                failures += excesses.map { "\(benchmark.name): \($0)" }
                line += excesses.isEmpty ? "  ok" : "  OVER: " + excesses.joined(separator: ", ")
            } else {
                failures.append("\(benchmark.name): no limit recorded for this machine")
                line += "  no limit"
            }
            print(line)
        }
        if options.record {
            limits.machines[machine] = recorded
            try limits.write(to: options.limits)
            print("limits written to \(options.limits.path)")
        }
        for failure in failures {
            print("FAIL \(failure)")
        }
        return failures.isEmpty ? 0 : 1
    }
}
