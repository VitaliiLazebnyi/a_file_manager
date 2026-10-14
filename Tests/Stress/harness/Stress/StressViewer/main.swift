import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import StressKit
import TestSupport

// Scenario 7: the viewer's text model (TextDocument / TextRowIndex / ViewerSearch) and the real
// TextPagerView on top of it, without a window.
//
//   StressViewer gen <dir>                      dense4g.txt, sparse4g.txt, line2g.txt, newlines1g.txt (11 GiB)
//   StressViewer dense <file> <megabytes>       one dense text file of that size
//   StressViewer leak <file> <resultsDir>       memory per call of the model's entry points (search above all)
//   StressViewer run <file> <resultsDir> [seed] one file through every step
//   StressViewer truncate <dir> <resultsDir> [rounds]   a file cut short (and removed) while it is indexed

private let kArguments = CommandLine.arguments

guard kArguments.count >= 3 else {
    say("usage")
    exit(2)
}

if kArguments[1] == "gen" {
    ViewerFiles.generate(URL(fileURLWithPath: kArguments[2]))
    exit(0)
}
// One dense text file of a chosen size: `StressViewer dense <file> <megabytes>`.
if kArguments[1] == "dense", kArguments.count >= 4, let megabytes = Int(kArguments[3]), megabytes >= 1 {
    let lines = ViewerFiles.writeDense(URL(fileURLWithPath: kArguments[2]), megabytes: megabytes)
    say("\(kArguments[2]): \(megabytes) MiB, \(lines) lines")
    exit(0)
}

// MARK: Common

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
MainWatchdog.shared.start()
HangGuard.shared.sampleDirectory = kArguments[3]

private let kKernel = Kernel(productName: "Stress", settings: MemorySettings(), interaction: ScriptedInteraction())

kKernel.fileSystems.register(LocalFileSystem())

/// The number in argument `index` when there is one; ends the process with the usage when it is not a number.
@MainActor
private func optionalNumber<Number: FixedWidthInteger>(_ index: Int, otherwise: Number) -> Number {
    guard kArguments.count > index else {
        return otherwise
    }
    guard let number = Number(kArguments[index]) else {
        say("usage")
        exit(2)
    }
    return number
}

switch kArguments[1] {
case "leak":
    LeakRun.run(URL(fileURLWithPath: kArguments[2]), fileSystems: kKernel.fileSystems)
    exit(0)

case "run":
    FileRun.run(
        URL(fileURLWithPath: kArguments[2]),
        seed: optionalNumber(4, otherwise: UInt64(1)),
        fileSystems: kKernel.fileSystems
    )

case "truncate":
    TruncationRun.run(
        URL(fileURLWithPath: kArguments[2]),
        rounds: optionalNumber(4, otherwise: 12),
        fileSystems: kKernel.fileSystems
    )

default:
    say("usage")
    exit(2)
}

if let hold = Options.hold {
    say("holding for \(hold) s, pid \(getpid()), footprint \(footprintMB()) MB")
    pump(for: hold)
}
MainWatchdog.shared.report(title: "scenario 7, viewer: " + kArguments[2])
Failures.shared.report()
say(String(format: "peak RSS %.0f MB, threads %d, load %.1f", peakRSSMB(), threadCount(), loadAverage()))
exit(Failures.shared.isEmpty ? 0 : 1)
