internal import Darwin
internal import Foundation
internal import StressKit

// Scenario 3: Parallel.map torture. `StressParallel` runs everything; `StressParallel child <case>`
// runs one of the cases that are expected to deadlock or crash, for the parent to watch.

setvbuf(stdout, nil, _IOLBF, 0)
/// Where samples go: `STRESS_RESULTS`, else the current folder.
internal let kResultsDirectory =
    ProcessInfo.processInfo.environment["STRESS_RESULTS"] ?? FileManager.default.currentDirectoryPath

HangGuard.shared.sampleDirectory = kResultsDirectory

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "child" {
    ChildCases.run(CommandLine.arguments[2])
}

exit(ParallelRun(resultsDirectory: kResultsDirectory).runAll() ? 0 : 1)
