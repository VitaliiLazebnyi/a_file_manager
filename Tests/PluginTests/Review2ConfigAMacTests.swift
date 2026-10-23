import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import MacIntegrationPlugin

/// The Mac integration with a long list (review 2): the marked items are picked out away from
/// the main thread, nothing unbounded is handed to Finder or the sharing panel, and the log
/// keeps short lines.
@MainActor
@Suite
internal struct Review2ConfigAMacTests {
    /// The folder on disk: `A` with `count` empty files, `S` with a name that has a line break, and an empty `B`.
    internal let box: Sandbox
    private let scratch = ScratchPasteboard()
    /// The pasteboard the plugin copies to, the test's own.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }
    /// The plugin, which starts nothing and records what it would have opened.
    internal let mac: MacIntegrationPlugin
    /// The kernel with navigation, selection and the plugin; `A` on the left, `B` on the right.
    internal let bench: TestBench
    /// How many files `A` has: a few more than are picked out in the background.
    internal let count: Int

    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The scripted answers to the plugin's questions, and the log of them.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// Makes the folders and starts the kernel; every file opens with one application.
    internal init() throws {
        box = try Sandbox()
        count = MacIntegrationPlugin.backgroundListThreshold + 10
        let folder = try box.folder("A")
        for number in 0..<count {
            FileManager.default.createFile(atPath: folder.appendingPathComponent("f\(number).txt").path, contents: nil)
        }
        try box.file("S/line\nbreak.txt")
        try box.folder("B")
        mac = MacIntegrationPlugin(launchesApplications: false, pasteboard: scratch.pasteboard) { _ in
            [URL(fileURLWithPath: "/Applications/First.app")]
        }
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), mac],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
    }

    /// Lets the main thread run until `done` holds, or the ceiling of waits has passed.
    internal func wait(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// Thousands of marked items are picked out in the background, in list order; Finder is shown a
    /// bounded number of them and too many are not shared.
    @Test
    internal func theMarkedItemsOfALongListArePickedOutInTheBackground() async {
        commands.perform(.selectAll)
        #expect(bench.left.model.selectionCount == count)
        commands.perform(MacIntegrationPlugin.copyAsPathname)
        // Not done on the spot: the list is worked through elsewhere.
        #expect(pasteboard.string(forType: .string) == nil)
        await wait { pasteboard.string(forType: .string) != nil }
        let paths = (pasteboard.string(forType: .string) ?? "").split(separator: "\n")
        #expect(
            paths.count == count && Set(paths).count == count
                && paths.allSatisfy { $0.hasPrefix(bench.left.model.directory.path + "/f") }
        )
        // In list order, as the operands are.
        #expect(paths.map(String.init) == bench.left.model.items.map(\.url.path))

        commands.perform(MacIntegrationPlugin.quickLook)
        commands.perform(.revealInFinder)
        commands.perform(MacIntegrationPlugin.share)
        await wait { interaction.log.contains { $0.hasPrefix("inform:") } && mac.log.count == 2 }
        // The log says how many, Finder is shown a bounded number, and too many are not shared.
        #expect(mac.log.sorted() == ["quicklook \(count) items", "reveal \(MacIntegrationPlugin.revealLimit) items"])
        #expect(interaction.log == ["inform: Too many items to share"])
    }

    /// Two marked items of a long list are both copied and shared.
    @Test
    internal func aFewMarkedItemsOfALongListAreStillAllOfThem() async {
        bench.left.model.setSelected(true, names: ["f7.txt", "f3.txt"])
        commands.perform(MacIntegrationPlugin.copyAsPathname)
        await wait { pasteboard.string(forType: .string) != nil }
        let names = (pasteboard.string(forType: .string) ?? "").split(separator: "\n")
            .map { line in URL(fileURLWithPath: String(line)).lastPathComponent }
        #expect(Set(names) == ["f3.txt", "f7.txt"] && names.count == 2)
        commands.perform(MacIntegrationPlugin.share)
        await wait { mac.log.count == 1 }
        #expect(
            mac.log.first?.hasPrefix("share ") == true && mac.log.first?.contains("f3.txt") == true
                && interaction.log.isEmpty
        )
    }

    /// Without marked items the file under the cursor is acted on at once.
    @Test
    internal func withoutMarksNothingWaits() {
        bench.left.moveCursor(toName: "f1.txt")
        commands.perform(MacIntegrationPlugin.copyAsPathname)
        #expect(pasteboard.string(forType: .string) == bench.left.model.directory.path + "/f1.txt")
        commands.perform(MacIntegrationPlugin.quickLook)
        #expect(mac.log == ["quicklook " + bench.left.model.directory.path + "/f1.txt"])
    }

    /// A name with a line break makes one log line, and one line in the question of Open With.
    @Test
    internal func aNameWithALineBreakMakesOneLogLine() {
        bench.left.show(box.url("S"))
        bench.left.moveCursor(toName: "line\nbreak.txt")
        commands.perform(.edit)
        commands.perform(MacIntegrationPlugin.openWithDefault)
        interaction.formAnswers = [.accept]
        commands.perform(MacIntegrationPlugin.openWith)
        #expect(mac.log.count == 3 && mac.log.allSatisfy { !$0.contains("\n") && $0.hasSuffix("line\\nbreak.txt") })
        #expect(mac.log[2].hasPrefix("open-with First ") && mac.opened.count == 3)
        // The question names the file on one line too.
        #expect(interaction.log == ["form: Open “line\\nbreak.txt” with"])
    }
}
