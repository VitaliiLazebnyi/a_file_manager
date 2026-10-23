import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Download lists that pause, copy, move, and name their files in ways the disk refuses.
@MainActor
@Suite
internal struct CoverageNetworkListRuns {
    private let fixture: CoverageNetworkBench

    private var scripted: ScriptedInteraction { fixture.scripted }

    /// A fresh bench, connected to its server.
    internal init() throws {
        fixture = try CoverageNetworkBench()
        fixture.quickConnect("ftp://\(fixture.address)/")
    }

    /// A list pauses, copies between two local places, moves from the server, and skips what
    /// it cannot reach.
    @Test
    internal func aListPausesCopiesAndMoves() async throws {
        let copy = fixture.box.url("other/copy.txt")
        let moved = fixture.box.url("other/moved.txt")
        try fixture.runList(
            [
                "sleep:0",
                "copy:\(fixture.box.url("local/up.txt").path) -> \(copy.path)",
                "move:ftp://\(fixture.address)/readme.txt -> \(moved.path)",
                "gopher://old.invalid/file"
            ],
            answers: [0]
        )
        let question = try #require(scripted.log.first { $0.hasPrefix("choose: Run this download list?") })
        #expect(question.contains("Copy: ") && question.contains("1 lines will not be carried out."))
        #expect(
            await fixture.settle {
                scripted.log.last == "inform: Some lines of the download list were not carried out."
            }
        )
        #expect(fixture.box.read("other/copy.txt") == "upload" && fixture.box.read("other/moved.txt") == "read me")
        #expect(!fixture.box.exists("srv/readme.txt"))
    }

    /// A name the disk refuses leaves the file under the name it came with, and says why.
    @Test
    internal func aNameTheDiskRefusesIsReported() throws {
        let name = String(repeating: "n", count: 300) + ".txt"
        let target = fixture.box.url("other").appending(path: name)
        try fixture.runList(["ftp://\(fixture.address)/pub/report.txt -> \(target.path)"], answers: [0])
        #expect(fixture.box.read("other/report.txt") == "report")
        #expect(scripted.log.last == "inform: Some lines of the download list were not carried out.")
        let skipped = ListPlan.shortened([target.path + ": too long"])
        #expect(skipped.count == 301 && skipped.hasSuffix("\u{2026}"))
    }

    /// The steps of a plan leave out its pauses.
    @Test
    internal func theStepsOfAPlanLeaveOutItsPauses() {
        let plan = ListPlan(
            actions: [.pause(1), .download(source: "ftp://\(fixture.address)/readme.txt", target: nil)],
            base: fixture.box.url("other"),
            fileSystems: fixture.bench.kernel.fileSystems
        )
        #expect(plan.items.count == 2 && plan.steps.count == 1)
        #expect(plan.steps.first?.destination == fixture.box.url("other").appending(path: "readme.txt"))
    }
}
