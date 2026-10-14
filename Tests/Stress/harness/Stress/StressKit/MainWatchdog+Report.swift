internal import Foundation

/// The watchdog's report: the table of phases, the histogram and the stacks of long stalls.
extension MainWatchdog {
    /// Prints the table of phases, the histogram and the sampled stacks of long stalls.
    public func report(title: String) {
        let recorded = snapshot()
        say("\n==== MAIN-THREAD WATCHDOG: \(title) ====")
        let bounds = Self.bounds.map { String(format: "%g", $0) }.joined(separator: " <")
        say("histogram bounds (ms): <" + bounds + " >=5000")
        say(
            "(max cpu = processor time the main thread used during its longest stall; stall ms / cpu ms = sums over "
                + "all stalls > 8 ms: equal means the main thread was working, cpu much smaller means it was blocked "
                + "or had no core)"
        )
        say(pad("phase") + "   wall s   pings   >8ms >100ms    >1s    max ms  max cpu  stall ms    cpu ms  histogram")
        var total = Stats()
        for name in recorded.order {
            guard let phase = recorded.stats[name], phase.pings > 0 || phase.wall > 0 else {
                continue
            }
            let figures = String(
                format: " %8.2f %7d %6d %6d %6d %9.1f %8.1f %9.0f %9.0f  ",
                phase.wall,
                phase.pings,
                phase.over8,
                phase.over100,
                phase.over1000,
                phase.maxMs,
                phase.maxCPUMs,
                phase.stallMs,
                phase.stallCPUMs
            )
            say(pad(name) + figures + phase.histogram.map(String.init).joined(separator: ","))
            total.add(phase)
        }
        let totals = String(
            format: " %8.2f %7d %6d %6d %6d %9.1f %8@ %9.0f %9.0f",
            total.wall,
            total.pings,
            total.over8,
            total.over100,
            total.over1000,
            total.maxMs,
            "",
            total.stallMs,
            total.stallCPUMs
        )
        say(pad("TOTAL") + totals)
        reportLongStalls(recorded.stalls)
    }

    /// Prints, for each phase, the stacks of the two longest stalls over 100 ms with different stacks.
    private func reportLongStalls(_ stalls: [Stall]) {
        var perPhase: [String: Int] = [:]
        var seen = Set<String>()
        let long = stalls.filter { $0.milliseconds > 100 && !$0.stacks.isEmpty }
        let longestFirst = long.sorted { $0.milliseconds > $1.milliseconds }
        for stall in longestFirst where perPhase[stall.phase, default: 0] < 2 {
            let frames = stall.stacks[0].prefix(8)
            let top = frames.map { $0.split(separator: " ", maxSplits: 3).last.map(String.init) ?? $0 }
            guard seen.insert(stall.phase + "|" + top.joined()).inserted else {
                continue
            }
            perPhase[stall.phase, default: 0] += 1
            let head = String(
                format: "\n-- stall %.0f ms (main thread cpu %.0f ms) at t=%.2fs in phase '%@'; "
                    + "main thread stack at +100 ms:",
                stall.milliseconds,
                stall.mainCPUMilliseconds,
                stall.sentAt,
                stall.phase
            )
            say(head)
            for line in stall.stacks[0].prefix(34) {
                say("   " + line)
            }
            if stall.stacks.count > 1 {
                say("   .. and at +1 s:")
                for line in stall.stacks[1].prefix(26) {
                    say("   " + line)
                }
            }
        }
    }
}
