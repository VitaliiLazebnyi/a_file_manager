import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// The commands that register the plugin and change attributes, driven through a kernel with fake panels.
@MainActor
@Suite
internal struct FilePropertiesAttributeCommands {
    /// The kernel, its panels and the files.
    private let fixture: FilePropertiesBench

    /// The kernel's commands.
    private var commands: CommandRegistry { fixture.commands }
    /// The panel on `A`.
    private var left: FakePanel { fixture.left }
    /// The panel on `B`.
    private var right: FakePanel { fixture.right }
    /// The dialogs and messages, answered by script.
    private var dialogs: ScriptedInteraction { fixture.dialogs }

    /// A fresh sandbox and kernel for each test.
    internal init() throws {
        fixture = try FilePropertiesBench()
    }

    /// The plugin brings its commands, keys, menu, columns, toolbar buttons and settings page.
    @Test
    internal func registersCommandsMenusKeysAndColumns() {
        let keys = fixture.bench.kernel.keyBindings
        #expect(fixture.bench.kernel.keyClashes.isEmpty)
        #expect(
            keys.command(for: Shortcut(.returnKey, .option)) == .properties
                && keys.command(for: .cmd("i")) == .properties
        )
        #expect(keys.command(for: Shortcut(.character("l"), .control)) == .occupiedSpace)
        #expect(keys.command(for: Shortcut(.character("z"), .control)) == "cm_EditComment")
        #expect(keys.command(for: .f(5, [.control, .shift])) == "cm_CreateShortcut")
        let files = fixture.bench.kernel.menus.menus.first { $0.title == "Files" }?.items ?? []
        #expect(
            files == [
                .setAttributes, .properties, "afm_FinderInfo", .occupiedSpace, "cm_CountDirContent", "cm_EditComment",
                nil,
                "cm_CreateShortcut", "afm_ShowLinkTarget"
            ]
        )
        #expect(files.compactMap(\.self).allSatisfy { commands[$0] != nil })
        #expect(fixture.bench.kernel.columns["comment"] != nil && fixture.bench.kernel.columns.all.count == 11)
        #expect(fixture.bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [.properties, .occupiedSpace])
        #expect(fixture.bench.kernel.preferences.pages.map(\.title) == ["File properties"])
    }

    // MARK: Change attributes

    /// The dialog shows one file's state and changes its permissions, date and flags.
    @Test
    internal func changesPermissionsDateAndFlagsOfOneFile() {
        left.moveCursor(toName: "one.txt")
        dialogs.formAnswers = [
            .values([
                "permissions": .text("600"), "changeDate": .flag(true), "date": .text("2001-02-03"),
                "time": .text("hh:00"),
                "locked": .index(1)
            ])
        ]
        commands.perform(.setAttributes)
        #expect(dialogs.log.contains("form: Change attributes: one.txt"))
        // The dialog showed the file's own state.
        let form = dialogs.forms[0]
        #expect(form.first { $0.key == "permissions" }?.initialValue == .text("644"))
        if case .choice(let options, _)? = form.first(where: { $0.key == "hidden" })?.kind {
            #expect(options[0] == "Unchanged (not set)")
        }
        #expect(fixture.notes(form).contains { $0.hasPrefix("Owner (now \(NSUserName()))") })
        #expect(fixture.mode("A/one.txt") == 0o600 && fixture.flags("A/one.txt") & UInt32(UF_IMMUTABLE) != 0)
        let texts = TimestampChange.fieldTexts(for: left.model.items.first { $0.name == "one.txt" }?.modified ?? Date())
        #expect(texts.date == "2001-02-03" && texts.time.hasSuffix(":00:00"))

        // A locked file is unlocked before anything else is changed.
        dialogs.formAnswers = [.values(["permissions": .text("u+x"), "locked": .index(2), "hidden": .index(1)])]
        commands.perform(.setAttributes)
        #expect(fixture.mode("A/one.txt") == 0o700 && fixture.flags("A/one.txt") & UInt32(UF_IMMUTABLE) == 0)
        // Hidden now, so the panel no longer lists it.
        #expect(fixture.flags("A/one.txt") & UInt32(UF_HIDDEN) != 0 && left.names == ["docs", "two.txt"])
        #expect(!dialogs.log.contains { $0.hasPrefix("inform") })
    }

    /// Several items change at once, with or without what folders hold.
    @Test
    internal func changesSeveralItemsWithAndWithoutTheirContents() {
        left.model.selectAll()
        dialogs.formAnswers = [.values(["permissions": .text("go-r")])]
        commands.perform(.setAttributes)
        #expect(dialogs.log.contains("form: Change attributes: 3"))
        // Several items start unchanged: no permissions proposed, letters in the date fields.
        #expect(dialogs.forms[0].first { $0.key == "permissions" }?.initialValue == .text(""))
        #expect(dialogs.forms[0].first { $0.key == "date" }?.initialValue == .text("yyyy-mm-dd"))
        #expect(
            fixture.mode("A/one.txt") == 0o600 && fixture.mode("A/docs") == 0o711
                && fixture.mode("A/docs/in.txt") == 0o644
        )
        dialogs.formAnswers = [.values(["permissions": .text("go-r"), "recurse": .flag(true), "current": .flag(true)])]
        commands.perform(.setAttributes)
        #expect(
            fixture.mode("A/docs/in.txt") == 0o600 && fixture.mode("A/docs/deep/more.txt") == 0o600
                && fixture.mode("A/docs/deep") == 0o711
        )
        let changed = LocalInfo.details(fixture.box.url("A/docs/deep/more.txt"))?.modified ?? .distantPast
        #expect(abs(changed.timeIntervalSinceNow) < 60)
        // The selection the command started from can be brought back.
        left.model.clearSelection()
        left.model.restoreSelection()
        #expect(left.model.selectionCount == 3)
    }

    /// A wrong entry is asked again with what was typed; the target file's values can be loaded.
    @Test
    internal func wrongEntriesAreAskedAgainAndTargetFileCanBeLoaded() {
        left.moveCursor(toName: "two.txt")
        right.moveCursor(toName: "other.txt")
        dialogs.formAnswers = [
            .values(["permissions": .text("abc")]),
            .values(["permissions": .text(""), "changeDate": .flag(true), "date": .text("soon")]),
            .values([:], button: 1), .accept
        ]
        commands.perform(.setAttributes)
        #expect(dialogs.log.filter { $0.hasPrefix("form: Change attributes") }.count == 4)
        #expect(dialogs.log.contains("inform: The permissions \"abc\" cannot be read!"))
        #expect(dialogs.log.contains { $0.hasPrefix("inform: The date \"soon\"") })
        // What was typed is still there the second time; the target's values the fourth.
        #expect(dialogs.forms[1].first { $0.key == "permissions" }?.initialValue == .text("abc"))
        #expect(dialogs.forms[3].first { $0.key == "changeDate" }?.initialValue == .flag(true))
        let two = LocalInfo.details(fixture.box.url("A/two.txt"))?.modified
        #expect(two == Date(timeIntervalSince1970: 86_400 * 365))
        // Cancel changes nothing.
        dialogs.formAnswers = [.cancel]
        commands.perform(.setAttributes)
        #expect(fixture.mode("A/two.txt") == 0o644)
    }

    /// Parameters with `=` change without a dialog; what cannot be changed is reported.
    @Test
    internal func parametersApplyWithoutADialogAndFailuresAreReported() {
        left.moveCursor(toName: "two.txt")
        commands.perform(.setAttributes, .text("=+h +m640"))
        #expect(
            dialogs.forms.isEmpty && fixture.mode("A/two.txt") == 0o640
                && fixture.flags("A/two.txt") & UInt32(UF_HIDDEN) != 0
        )
        commands.perform(.setAttributes, .text("+nonsense"))
        #expect(dialogs.log.last == "inform: The attribute parameters cannot be read!")
        // Without `=` the dialog opens with the parameters filled in.
        left.moveCursor(toName: "one.txt")
        dialogs.formAnswers = [.accept]
        commands.perform(.setAttributes, .text("+r +f +d2020-01-02"))
        let form = dialogs.forms[0]
        #expect(
            form.first { $0.key == "recurse" }?.initialValue == .flag(true)
                && form.first { $0.key == "locked" }?.initialValue == .index(1)
        )
        #expect(
            form.first { $0.key == "date" }?.initialValue == .text("2020-01-02")
                && form.first { $0.key == "time" }?.initialValue == .text("hh:mm:ss")
        )
        #expect(fixture.flags("A/one.txt") & UInt32(UF_IMMUTABLE) != 0)
        commands.perform(.setAttributes, .text("=-r"))

        // A file system that cannot change attributes says so; flags are not offered there.
        left.show(fixture.memory.url("/M"))
        left.moveCursor(toName: "a.txt")
        dialogs.formAnswers = [.values(["permissions": .text("600")])]
        commands.perform(.setAttributes)
        #expect(dialogs.forms[1].allSatisfy { $0.key != "hidden" && $0.key != "owner" })
        #expect(dialogs.log.last == "inform: 1 item(s) could not be changed!")
        commands.perform(.setAttributes, .text("=+h"))
        #expect(dialogs.log.last == "inform: 1 item(s) could not be changed!")
        // On [..] there is nothing to change.
        left.model.moveCursor(to: 0)
        #expect(!commands.isEnabled(.setAttributes))
    }

    /// An owner that does not exist is refused; a group given by number is set.
    @Test
    internal func anUnknownOwnerIsRefused() {
        left.moveCursor(toName: "two.txt")
        dialogs.formAnswers = [
            .values(["owner": .text("no-such-user-afm")]), .values(["group": .text(String(getgid()))])
        ]
        commands.perform(.setAttributes)
        #expect(dialogs.log.last == "inform: 1 item(s) could not be changed!")
        commands.perform(.setAttributes)
        #expect(
            dialogs.log.last?.hasPrefix("form:") == true
                && LocalInfo.details(fixture.box.url("A/two.txt"))?.groupID == getgid()
        )
    }
}
