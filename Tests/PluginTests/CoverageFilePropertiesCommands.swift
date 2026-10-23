import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// The commands of file properties beyond the other suites: Finder's Info for many items or
/// for the folder, permissions given to a folder's contents after a question, properties that
/// cannot be read, and dialogs that are cancelled or answered out of range.
@MainActor
@Suite
internal struct CoverageFilePropertiesCommands {
    /// The kernel, its panels and the files: `A` and `B` on the disk, `/M` in memory.
    private let fixture: FilePropertiesBench

    /// The kernel's commands.
    private var commands: CommandRegistry { fixture.commands }
    /// The panel on `A`.
    private var left: FakePanel { fixture.left }
    /// The dialogs and messages, answered by script.
    private var dialogs: ScriptedInteraction { fixture.dialogs }

    /// A fresh sandbox and kernel for each test.
    internal init() throws {
        fixture = try FilePropertiesBench()
    }

    /// Finder's Info is asked for the first marked items only, and for the folder itself
    /// when nothing is marked and the cursor is on `[..]`.
    @Test
    internal func finderInfoForManyItemsAndForTheFolder() throws {
        for index in 0..<70 { try fixture.box.file("A/many/f\(index).txt") }
        left.show(fixture.box.url("A/many"))
        left.model.selectAll()
        commands.perform("afm_FinderInfo")
        #expect(fixture.plugin.finderInfoRequests.count == 64)
        left.model.clearSelection()
        left.model.moveCursor(to: 0)
        commands.perform("afm_FinderInfo")
        #expect(fixture.plugin.finderInfoRequests.last?.path == fixture.box.url("A/many").path)
    }

    /// Recursing with the permissions left as shown asks first: Back returns to the dialog,
    /// Apply gives everything inside the folder's permissions.
    @Test
    internal func permissionsLeftAsShownAreGivenAfterAQuestion() {
        left.moveCursor(toName: "docs")
        dialogs.formAnswers = Array(repeating: .values(["recurse": .flag(true)]), count: 3)
        dialogs.choiceAnswers = [1, 0]
        commands.perform(.setAttributes)
        #expect(dialogs.log.filter { $0.hasPrefix("choose: Nothing was changed.") }.count == 2)
        #expect(fixture.mode("A/docs/in.txt") == 0o755 && fixture.mode("A/docs/deep") == 0o755)
    }

    /// Parameters that set or clear the hidden and locked flags are shown in the dialog.
    @Test
    internal func flagParametersAreShownInTheDialog() {
        left.moveCursor(toName: "two.txt")
        dialogs.formAnswers = [.cancel, .cancel]
        commands.perform(.setAttributes, .text("+h +r"))
        commands.perform(.setAttributes, .text("-h -r"))
        let shown = dialogs.forms.map { form in
            [form.first { $0.key == "hidden" }?.initialValue, form.first { $0.key == "locked" }?.initialValue]
        }
        #expect(shown == [[.index(1), .index(1)], [.index(2), .index(2)]])
        #expect(fixture.flags("A/two.txt") == 0)
    }

    /// The properties of a folder that has gone cannot be read, which is said.
    @Test
    internal func propertiesOfAFolderThatHasGone() {
        left.show(fixture.memory.url("/M/sub"))
        left.model.moveCursor(to: 0)
        fixture.memory.removeTree("/M/sub")
        commands.perform(.properties)
        #expect(dialogs.log == ["inform: The properties of sub cannot be read!"])
    }

    /// A list whose only folder is a link to one has no folder sizes to show.
    @Test
    internal func folderSizesWhereTheOnlyFolderIsALink() throws {
        try fixture.box.folder("A/links")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.box.url("A/links/to-docs").path,
            withDestinationPath: fixture.box.url("A/docs").path
        )
        left.show(fixture.box.url("A/links"))
        commands.perform("cm_CountDirContent")
        #expect(fixture.bench.jobService.titles == ["Calculating folder sizes:"])
        #expect(left.model.items.allSatisfy { $0.computedSize == nil })
    }

    /// Create Link: a cancelled dialog, an empty target and a type out of range.
    @Test
    internal func createLinkAnswers() {
        left.moveCursor(toName: "one.txt")
        fixture.right.show(URL(fileURLWithPath: "/"))
        commands.perform("cm_CreateShortcut")
        #expect(dialogs.forms.first?.first?.initialValue == .text("/one.txt"))
        fixture.right.show(fixture.box.url("B"))
        dialogs.formAnswers = [.values(["target": .text("  ")]), .values(["kind": .index(9)])]
        for _ in 0..<2 { commands.perform("cm_CreateShortcut") }
        #expect(fixture.bench.jobService.titles == ["Creating links:"])
        #expect(LocalInfo.linkTarget(fixture.box.url("B/one.txt")) == fixture.box.url("A/one.txt").path)
    }
}
