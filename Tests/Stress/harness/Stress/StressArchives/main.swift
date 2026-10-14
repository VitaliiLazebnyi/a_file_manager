import AppKit
import Foundation
import StressKit

// Scenario 5: archives. `--mode big` opens and lists the 200,000-member ZIP and then lets 16
// threads read 64 members (with random cancels) while one thread adds members and commits and
// another lists; after every commit the archive is checked with unzip, zipinfo and a fresh
// reader of the program's own. `--mode deep` walks the deeply nested ZIP.

/// The command line.
internal let kOptions = Options(commandLine: CommandLine.arguments)

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
HangGuard.shared.sampleDirectory = kOptions.results
MainWatchdog.shared.start()
say(
    "StressArchives mode=\(kOptions.mode) dir=\(kOptions.directory.path) "
        + "cores=\(ProcessInfo.processInfo.activeProcessorCount) load=\(loadAverage())"
)
step("idle baseline") { pump(for: 1.5) }

/// The threads of the process before the run.
internal let kBaselineThreads = threadCount()

if kOptions.mode == "big" {
    BigRun(options: kOptions).run(baselineThreads: kBaselineThreads)
} else {
    DeepRun(options: kOptions).run()
}
MainWatchdog.shared.setPhase("end")
Counter.shared.report()
Findings.shared.summary()
MainWatchdog.shared.report(title: "StressArchives \(kOptions.mode)")
say(
    String(
        format: "FINAL threads=%d (baseline %d) peakRSS=%.0fMB footprint=%.0fMB load=%.1f",
        threadCount(),
        kBaselineThreads,
        peakRSSMB(),
        footprintMB(),
        loadAverage()
    )
)
exit(Findings.shared.isEmpty ? 0 : 3)
