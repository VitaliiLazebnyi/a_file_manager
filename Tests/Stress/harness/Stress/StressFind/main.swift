internal import AppKit
internal import Foundation
internal import StressKit

// Scenario 6: the Find Files engine and its window controller (headless, never shown).
//
//   StressFind gen <tree> [folders [bigMB]]                 builds the nested tree (2000 folders,
//                                                           two files of 256 MB; less for a smoke run)
//   StressFind run <tree> <million|-> <resultsDir> <cancels> [seed]
//
// The engine is driven both directly (FileSearch.run on a background thread) and through the
// real FindFilesWindowController (prepare/startSearch/cancelSearch), whose own batching hands
// the results to the main queue.

/// The command line.
internal let kArguments = CommandLine.arguments

guard kArguments.count >= 3 else {
    say("usage")
    exit(2)
}

if kArguments[1] == "gen" {
    let folders = kArguments.count > 3 ? Int(kArguments[3]) : FindTree.fullFolders
    let bigMegabytes = kArguments.count > 4 ? Int(kArguments[4]) : FindTree.fullBigMegabytes
    guard let folders, let bigMegabytes, (1...10_000).contains(folders), bigMegabytes >= 0 else {
        say("usage")
        exit(2)
    }
    let started = now()
    FindTree.generate(URL(fileURLWithPath: kArguments[2]), folders: folders, bigMegabytes: bigMegabytes)
    say(String(format: "generated in %.1fs", now() - started))
    exit(0)
}

guard
    kArguments.count >= 6,
    let kCancels = Int(kArguments[5]),
    let kSeed = kArguments.count > 6 ? UInt64(kArguments[6]) : 1
else {
    say("usage")
    exit(2)
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
MainWatchdog.shared.start()
HangGuard.shared.sampleDirectory = kArguments[4]

/// The run over the tree and, unless its argument is a dash, the million folder.
internal let kRun = FindRun(
    tree: URL(fileURLWithPath: kArguments[2], isDirectory: true),
    million: kArguments[3] == "-" ? nil : URL(fileURLWithPath: kArguments[3], isDirectory: true),
    cancels: kCancels,
    seed: kSeed
)

exit(kRun.runAll() ? 0 : 1)
