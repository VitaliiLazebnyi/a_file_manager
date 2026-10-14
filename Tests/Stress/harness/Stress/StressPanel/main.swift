import AppKit
import Darwin
import StressKit

// Scenarios 1 (a million files in a panel), 2 (a provider that stops answering) and
// 8 (a flood of changes in a watched folder), driven through the real kernel, the standard
// plugins and the real shell, without showing a window.
//
//   StressPanel million <directory with the files> <work directory> [files made, default 1000000]
//   StressPanel stalled <work directory>
//   StressPanel flood <work directory> [files] [ops per second] [seconds]

setvbuf(stdout, nil, _IOLBF, 0)

private let kArguments = CommandLine.arguments

guard kArguments.count >= 3 else {
    say("usage: StressPanel million|stalled|flood ...")
    exit(2)
}

private let kMode = kArguments[1]

HangGuard.shared.sampleDirectory =
    ProcessInfo.processInfo.environment["STRESS_RESULTS"] ?? FileManager.default.currentDirectoryPath

/// What went wrong so far, in the order it was found.
private var failures: [String] = []

/// Records `what` as a failure when `condition` does not hold.
@MainActor
internal func check(_ condition: Bool, _ what: String) {
    if !condition {
        failures.append(what)
        say("FAIL: " + what)
    }
}

/// Makes `directory` with `files` one-byte files and an empty folder `sub`.
internal func makeSmall(_ directory: URL, files: Int) {
    let manager = FileManager.default
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<files {
        manager.createFile(atPath: directory.appendingPathComponent("small\(index).txt").path, contents: Data("x".utf8))
    }
    try? manager.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
}

/// Shuts the program down, waits for its threads, prints the report and ends the process.
@MainActor
internal func finish(_ title: String, baseline: Int, app: Running) -> Never {
    step("shut down") {
        app.stop()
        pump(for: 0.5)
    }
    let after = step("threads return to baseline (up to 8 s)") {
        waitForThreads(atMost: baseline + 2, upTo: 8)
    }
    say("threads: baseline(after start-up)=\(baseline) after shut-down=\(after)")
    MainWatchdog.shared.report(title: title)
    say("\nFAILURES: \(failures.count)")
    for failure in failures {
        say("  - " + failure)
    }
    say(String(format: "peakRSS=%.0fMB footprint=%.0fMB", peakRSSMB(), footprintMB()))
    exit(failures.isEmpty ? 0 : 1)
}

/// Runs `body` `count` times with a turn of the run loop after each; reports how long single calls took.
@MainActor
internal func timed(_ count: Int, _ body: (Int) -> Void) {
    var durations: [Double] = []
    durations.reserveCapacity(count)
    for index in 0..<count {
        let started = now()
        body(index)
        durations.append((now() - started) * 1_000)
        CFRunLoopRunInMode(.defaultMode, 0.0005, false)
    }
    durations.sort()
    say(
        String(
            format: "   single call: median %.2f ms, p99 %.2f ms, max %.2f ms, over 8 ms: %d of %d",
            durations[count / 2],
            durations[count * 99 / 100],
            durations[count - 1],
            durations.filter { $0 > 8 }.count,
            count
        )
    )
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
MainWatchdog.shared.start()

switch kMode {
case "million":
    MillionScenario(arguments: kArguments).run()

case "stalled":
    StalledScenario(arguments: kArguments).run()

case "flood":
    FloodScenario(arguments: kArguments).run()

default:
    say("unknown mode")
    exit(2)
}
