internal import AFMKernel
internal import Darwin
internal import Dispatch
internal import Foundation
internal import StressKit
internal import TestSupport

@testable internal import FindFilesPlugin

/// The engine alone: `FileSearch.run` on threads of its own, uncancelled and cancelled.
extension FindRun {
    /// Runs `test` once on a background thread while the main thread pumps; the results come
    /// back through the main queue.
    internal func runEngine(_ test: SearchCase) -> EngineResult {
        let search = makeSearch(test)
        let outcome = Shared<EngineResult?>(nil)
        let started = now()
        DispatchQueue.global(qos: .userInitiated)
            .async {
                var own: [FileItem] = []
                var firstAt = -1.0
                search.run { item in
                    if own.isEmpty {
                        firstAt = now() - started
                    }
                    own.append(item)
                }
                let result = EngineResult(items: own, seconds: 0, first: firstAt)
                DispatchQueue.main.async { outcome.value = result }
            }
        pump(upTo: 900) { outcome.value != nil }
        let items = outcome.value?.items ?? []
        return EngineResult(items: items, seconds: now() - started, first: outcome.value?.first ?? -1)
    }

    /// Every case twice: the results must be the truth, in the same order both times.
    internal func engineRuns() {
        var engineOrders: [String: [String]] = [:]
        for test in cases {
            for round in 0..<2 {
                step("engine: \(test.label) #\(round)", limit: 900) {
                    let result = runEngine(test)
                    say(
                        String(
                            format: "  engine %@: %d results in %.3fs, first after %.3fs",
                            test.label,
                            result.items.count,
                            result.seconds,
                            result.first
                        )
                    )
                    verify("engine " + test.label, result.items, against: test.expected, filesOnly: true)
                    let order = test.expected.count > 200_000 ? [] : result.items.map(\.url.path)
                    if let before = engineOrders[test.label], before != order {
                        fail("engine \(test.label): two runs gave a different order")
                    }
                    engineOrders[test.label] = order
                }
            }
        }
    }

    /// Eight searches of the tree at once, each from a thread of its own.
    internal func concurrentEngineRuns() {
        step("engine: 8 concurrent searches of the tree", limit: 600) {
            let outcomes = Shared<[(Int, [FileItem])]>([])
            let finished = Shared(false)
            let group = DispatchGroup()
            let twoCases = Array(cases.prefix(2))
            let fileSystems = fileSystems
            for index in 0..<8 {
                group.enter()
                Thread.detachNewThread {
                    let test = twoCases[index % 2]
                    let search = FileSearch(
                        SearchQuery(directory: test.directory, names: test.names, text: test.text),
                        fileSystems: fileSystems
                    )
                    var own: [FileItem] = []
                    search.run { own.append($0) }
                    outcomes.modify { $0.append((index % 2, own)) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { finished.value = true }
            pump(upTo: 600) { finished.value }
            for (which, items) in outcomes.value {
                verify("concurrent " + cases[which].label, items, against: cases[which].expected, filesOnly: true)
            }
        }
    }

    /// The same as the window's torture on the engine alone, cancelled from another thread; `run` must return.
    internal func cancelledEngineRuns() {
        var engineReturn: [Double] = []
        step("engine: \(cancels) runs cancelled from another thread", limit: Double(cancels) * 30 + 60) {
            for round in 0..<cancels {
                engineReturn.append(cancelledEngineRun(round))
            }
        }
        let returns = engineReturn.sorted()
        if let worst = returns.last {
            say(
                String(
                    format: "engine cancel -> run returned: median=%.1fms p95=%.1fms max=%.1fms",
                    returns[returns.count / 2] * 1_000,
                    returns[Int(Double(returns.count) * 0.95)] * 1_000,
                    worst * 1_000
                )
            )
        }
    }

    /// Twenty uncancelled text searches of the tree in a row: does each one add memory?
    internal func textSearchLoop() {
        for round in 0..<20 {
            _ = runEngine(cases[1])
            if round % 5 == 4 {
                Self.heapLine("after \(round + 1) more text searches of the tree")
            }
        }
        pump(for: 5)
        Self.heapLine("5 s after the last of them")
    }

    /// One engine run of the torture, cancelled at a random moment; how long `run` took to return
    /// after the cancel.
    private func cancelledEngineRun(_ round: Int) -> Double {
        let test = cases[Int(random.next() % UInt64(cases.count))]
        let delay = Double(random.next() % 1_000) / 1_000 * (typical[test.label] ?? 1)
        let search = makeSearch(test)
        let returnedAt = Shared<Double?>(nil)
        DispatchQueue.global(qos: .userInitiated)
            .async {
                search.run { _ in
                    // Only the return counts.
                }
                let finishedAt = now()
                DispatchQueue.main.async { returnedAt.value = finishedAt }
            }
        let canceller = Thread {
            usleep(UInt32(delay * 1_000_000))
            search.cancel()
        }
        let started = now()
        canceller.start()
        if !pump(upTo: delay + 30, until: { returnedAt.value != nil }) {
            fail("engine round \(round) \(test.label): run() did not return within 30 s of the cancel")
            HangGuard.shared.arm("engine run does not return", seconds: 0)
            pump(for: 600)
        }
        return max(0, (returnedAt.value ?? 0) - started - delay)
    }

    /// A search for `test` by the engine.
    private func makeSearch(_ test: SearchCase) -> FileSearch {
        FileSearch(
            SearchQuery(directory: test.directory, names: test.names, text: test.text),
            fileSystems: fileSystems
        )
    }
}
