internal import Foundation

// One measured step of a harness.

/// Runs `body` as one step: names the watchdog phase, gives it `limit` seconds before the hang guard
/// ends the process, and prints its wall time, processor time, memory and threads.
@discardableResult
public func step<Result>(_ name: String, limit: Double = 600, _ body: () throws -> Result) rethrows -> Result {
    MainWatchdog.shared.setPhase(name)
    HangGuard.shared.arm(name, seconds: limit)
    let (startTime, startCPU, startThreads) = (now(), cpuSeconds(), threadCount())
    let result = try body()
    let wall = now() - startTime
    let figures = String(
        format: " wall=%8.3fs cpu=%7.2fs threads %d->%d footprint=%.0fMB peakRSS=%.0fMB load=%.1f",
        wall,
        cpuSeconds() - startCPU,
        startThreads,
        threadCount(),
        footprintMB(),
        peakRSSMB(),
        loadAverage()
    )
    say("STEP " + pad(name) + figures)
    HangGuard.shared.disarm()
    return result
}
