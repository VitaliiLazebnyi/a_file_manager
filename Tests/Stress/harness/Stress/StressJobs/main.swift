import AppKit
import Foundation
import StressKit

// Scenario 4: FileJob under random cancel / pause / resume, on a real tree and on a
// destination that keeps writes back (`.deferredWrites`) with commits that fail at random.
//
// The jobs run through the shell's real ProgressJobService (pause gate, progress reports to
// the main thread, questions through `JobMonitor.ask`), with the main run loop pumping and the
// watchdog measuring it.

/// What the command line asked for.
internal let kSettings = Settings(commandLine: CommandLine.arguments)

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
HangGuard.shared.sampleDirectory = kSettings.results
MainWatchdog.shared.start()
say(
    "StressJobs root=\(kSettings.root.path) files=\(kSettings.fileCount) folders=\(kSettings.folderCount) "
        + "big=\(kSettings.bigCount) seeds=\(kSettings.seedCount) memseeds=\(kSettings.memSeeds) "
        + "cores=\(ProcessInfo.processInfo.activeProcessorCount) load=\(loadAverage())"
)

/// The runs on the local tree; its thread counts are those of the whole run.
internal let kLocal = LocalScenario(settings: kSettings)

step("idle baseline") { pump(for: 1.5) }

if !kSettings.skipLocal {
    kLocal.run()
}

if kSettings.memSeeds > 0 {
    DeferredScenario(settings: kSettings, baselineThreads: kLocal.baselineThreads).run()
}

if !kSettings.keepTree, !kSettings.skipLocal {
    let tree = kLocal.layout
    step("remove tree") {
        offMain { tree.removeAll() }
    }
}
MainWatchdog.shared.setPhase("end")
Findings.shared.summary()
MainWatchdog.shared.report(title: "StressJobs")
say(
    String(
        format: "FINAL threads=%d (baseline %d, max seen %d) peakRSS=%.0fMB footprint=%.0fMB load=%.1f",
        threadCount(),
        kLocal.baselineThreads,
        kLocal.maxThreads,
        peakRSSMB(),
        footprintMB(),
        loadAverage()
    )
)
exit(Findings.shared.isEmpty ? 0 : 3)
