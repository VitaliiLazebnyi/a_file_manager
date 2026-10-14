import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
@testable import MacIntegrationPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

/// The Mac integration with a long list (review 2): the marked items are picked out away from
/// the main thread, nothing unbounded is handed to Finder or the sharing panel, and the log
/// keeps short lines.
@MainActor @Suite struct Review2ConfigAMac {
    let box: Sandbox
    let pasteboard = NSPasteboard.withUniqueName()
    let mac: MacIntegrationPlugin
    let bench: TestBench
    let count: Int

    var commands: CommandRegistry { bench.commands }
    var ui: ScriptedInteraction { bench.ui }

    init() throws {
        box = try Sandbox()
        count = MacIntegrationPlugin.backgroundListThreshold + 10
        let folder = try box.folder("A")
        for number in 0..<count { FileManager.default.createFile(atPath: folder.appendingPathComponent("f\(number).txt").path, contents: nil) }
        try box.file("S/line\nbreak.txt")
        try box.folder("B")
        mac = MacIntegrationPlugin(launchesApplications: false, pasteboard: pasteboard) { _ in [URL(fileURLWithPath: "/Applications/First.app")] }
        bench = TestBench(plugins: [NavigationPlugin(), SelectionPlugin(), mac], fileSystems: [LocalFileSystem()], left: box.url("A"), right: box.url("B"))
    }

    func wait(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(60)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test func theMarkedItemsOfALongListArePickedOutInTheBackground() async {
        commands.perform(.selectAll)
        #expect(bench.left.model.selectionCount == count)
        commands.perform(MacIntegrationPlugin.copyAsPathname)
        // Not done on the spot: the list is worked through elsewhere.
        #expect(pasteboard.string(forType: .string) == nil)
        await wait { pasteboard.string(forType: .string) != nil }
        let paths = (pasteboard.string(forType: .string) ?? "").split(separator: "\n")
        #expect(paths.count == count && Set(paths).count == count && paths.allSatisfy { $0.hasPrefix(bench.left.model.directory.path + "/f") })
        // In list order, as the operands are.
        #expect(paths.map(String.init) == bench.left.model.items.map(\.url.path))

        commands.perform(MacIntegrationPlugin.quickLook)
        commands.perform(.revealInFinder)
        commands.perform(MacIntegrationPlugin.share)
        await wait { ui.log.contains { $0.hasPrefix("inform:") } && mac.log.count == 2 }
        // The log says how many, Finder is shown a bounded number, and too many are not shared.
        #expect(mac.log.sorted() == ["quicklook \(count) items", "reveal \(MacIntegrationPlugin.revealLimit) items"])
        #expect(ui.log == ["inform: Too many items to share"])
    }

    @Test func aFewMarkedItemsOfALongListAreStillAllOfThem() async {
        bench.left.model.setSelected(true, names: ["f7.txt", "f3.txt"])
        commands.perform(MacIntegrationPlugin.copyAsPathname)
        await wait { pasteboard.string(forType: .string) != nil }
        let names = (pasteboard.string(forType: .string) ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent }
        #expect(Set(names) == ["f3.txt", "f7.txt"] && names.count == 2)
        commands.perform(MacIntegrationPlugin.share)
        await wait { mac.log.count == 1 }
        #expect(mac.log.first?.hasPrefix("share ") == true && mac.log.first?.contains("f3.txt") == true && ui.log.isEmpty)
    }

    @Test func withoutMarksNothingWaits() {
        bench.left.moveCursor(toName: "f1.txt")
        commands.perform(MacIntegrationPlugin.copyAsPathname)
        #expect(pasteboard.string(forType: .string) == bench.left.model.directory.path + "/f1.txt")
        commands.perform(MacIntegrationPlugin.quickLook)
        #expect(mac.log == ["quicklook " + bench.left.model.directory.path + "/f1.txt"])
    }

    @Test func aNameWithALineBreakMakesOneLogLine() {
        bench.left.show(box.url("S"))
        bench.left.moveCursor(toName: "line\nbreak.txt")
        commands.perform(.edit)
        commands.perform(MacIntegrationPlugin.openWithDefault)
        ui.formAnswers = [.accept]
        commands.perform(MacIntegrationPlugin.openWith)
        #expect(mac.log.count == 3 && mac.log.allSatisfy { !$0.contains("\n") && $0.hasSuffix("line\\nbreak.txt") })
        #expect(mac.log[2].hasPrefix("open-with First ") && mac.opened.count == 3)
        // The question names the file on one line too.
        #expect(ui.log == ["form: Open “line\\nbreak.txt” with"])
    }
}
