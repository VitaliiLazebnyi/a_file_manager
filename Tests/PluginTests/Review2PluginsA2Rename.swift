import Foundation
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Round 2 of the review, second pass, Multi-Rename: plans that are cancelled, rings of renames, the fuzzer's masks and
/// files that are one file.
@Suite
internal struct Review2PluginsA2Rename {
    /// A plan of many renames is made in full, not at all, or cut short, as the cancel check answers.
    @Test
    internal func aPlanThatIsCancelledIsCutShort() {
        let sources = (0..<40_000).map { URL(fileURLWithPath: "/x/f\($0).txt") }
        let targets: [URL?] = (0..<40_000).map { URL(fileURLWithPath: "/x/g\($0).txt") }
        let planner = RenamePlanner()
        let all = planner.steps(sources: sources, targets: targets, isFolder: [], temporaryName: nil) { false }
        #expect(all.count == 40_000)
        #expect(planner.steps(sources: sources, targets: targets, isFolder: [], temporaryName: nil) { true }.isEmpty)
        var calls = 0
        let part = planner.steps(sources: sources, targets: targets, isFolder: [], temporaryName: nil) {
            calls += 1
            return calls > 2
        }
        #expect(part.count < 40_000)
    }

    /// A ring of renames is opened with one temporary name: one file parked and put back.
    @Test
    internal func aRingOfRenamesIsStillOpenedWithATemporaryName() {
        let sources = ["1", "2", "3"].map { URL(fileURLWithPath: "/x/\($0).txt") }
        let targets: [URL?] = ["2", "3", "1"].map { URL(fileURLWithPath: "/x/\($0).txt") }
        let steps = RenamePlanner()
            .steps(sources: sources, targets: targets, isFolder: [], temporaryName: nil) { false }
        #expect(
            steps.count == 4 && steps.filter { $0.kind == .park }.count == 1
                && steps.filter { $0.kind == .unpark }.count == 1
        )
    }

    /// The masks of the fuzzer's reproducers come to an end within the time limit.
    @Test
    internal func theFuzzerReproducersOfTheRenameMasksEnd() {
        // `renamemask-wildcard-backtracking.bin` and `renameregex-catastrophic.bin`: the text after the
        // choice bytes is name mask, extension mask, search, replacement and the name, one to a line.
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fuzz/repro/diff")
        for (file, regex) in [
            ("renamemask-wildcard-backtracking.bin", false), ("renameregex-catastrophic.bin", true)
        ] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { continue }
            let lines = data.dropFirst(13)
                .split(separator: 0x0A, omittingEmptySubsequences: false)
                .map { String(bytes: $0, encoding: .utf8) ?? "" }
            var settings = RenameSettings()
            settings.nameMask = lines[0]
            settings.extensionMask = lines[1]
            settings.search = lines[2]
            settings.replacement = lines[3]
            settings.regularExpression = regex
            var context = RenameContext()
            context.count = 3
            let subject = RenameSubject(
                name: lines[4],
                isFolder: false,
                size: 1,
                modified: Date(timeIntervalSince1970: 0),
                directoryPath: "/d",
                folders: ["d"],
                url: nil
            )
            let engine = RenameEngine(settings, context: context)
            let done = DispatchSemaphore(value: 0)
            Thread {
                _ = engine.newName(for: subject, index: 0)
                done.signal()
            }
            .start()
            #expect(done.wait(timeout: .now() + Wait.ceiling) == .success, "\(file)")
        }
    }

    /// Two URLs are the same file only when nothing else could be meant; a hard link is left to the listing.
    @Test
    internal func twoFilesAreTheSameFileOnlyWhenNothingElseCouldBeMeant() throws {
        let box = try Sandbox()
        let one = try box.file("one.txt")
        let other = try box.file("other.txt")
        #expect(RenameRunner.sameness(one, one) == .same)
        #expect(RenameRunner.sameness(one, other) == .different)
        #expect(RenameRunner.sameness(one, box.url("missing")) == .unknown)
        // A file with two names may be two files to the listing: it is left to it.
        let link = box.url("link.txt")
        try FileManager.default.linkItem(at: one, to: link)
        #expect(RenameRunner.sameness(one, link) == .unknown)
    }
}
