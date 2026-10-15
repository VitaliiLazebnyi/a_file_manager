import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The object that answers the menu bar's question whether a key belongs to an entry.
@MainActor
@Suite(.serialized)
internal struct AppMenuKeysTests {
    /// The target of the test's menu entries: it says yes through the general validation only.
    internal final class GeneralTarget: NSObject, NSUserInterfaceValidations {
        /// Whether the entries can be chosen.
        internal var isOffered = true
        /// The entries that ran, by title.
        internal private(set) var ran: [String] = []

        /// Runs an entry.
        @objc
        internal func run(_ sender: NSMenuItem) {
            ran.append(sender.title)
        }

        /// Whether an entry can be chosen now.
        internal func validateUserInterfaceItem(_: any NSValidatedUserInterfaceItem) -> Bool {
            isOffered
        }
    }

    /// A target that says nothing about its entries: they can always be chosen.
    internal final class SilentTarget: NSObject {
        /// The entries that ran, by title.
        internal private(set) var ran: [String] = []

        /// Runs an entry.
        @objc
        internal func run(_ sender: NSMenuItem) {
            ran.append(sender.title)
        }
    }

    /// A kernel without commands, for the bindings.
    private let kernel = Kernel(productName: "Keys", settings: MemorySettings(), interaction: ScriptedInteraction())

    /// Makes sure AppKit is there for the menus.
    internal init() {
        _ = NSApplication.shared
    }

    /// A standard entry whose key is a capital letter is Shift and that letter.
    @Test
    internal func aCapitalLetterAsTheKeyMeansShift() throws {
        let target = SilentTarget()
        let menu = NSMenu(title: "Edit")
        let redo = NSMenuItem(title: "Redo", action: #selector(SilentTarget.run(_:)), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = .command
        redo.target = target
        menu.addItem(redo)
        let keys = MenuKeys(kernel: kernel)
        keys.answer(for: menu)
        #expect(!menu.performKeyEquivalent(with: try AppRun.keyEvent(6, "z", .command)))
        #expect(menu.performKeyEquivalent(with: try AppRun.keyEvent(6, "z", [.command, .shift])))
        #expect(target.ran == ["Redo"])
    }

    /// An entry whose target validates in the general way is asked that way; one that does not validate is offered.
    @Test
    internal func anEntryIsAskedTheWayItsTargetAnswers() throws {
        let general = GeneralTarget()
        let menu = NSMenu(title: "Edit")
        let undo = NSMenuItem(title: "Undo", action: #selector(GeneralTarget.run(_:)), keyEquivalent: "z")
        undo.target = general
        menu.addItem(undo)
        let keys = MenuKeys(kernel: kernel)
        keys.answer(for: menu)
        general.isOffered = false
        var target: AnyObject?
        var action: Selector?
        let refused = keys.menuHasKeyEquivalent(
            menu,
            for: try AppRun.keyEvent(6, "z", .command),
            target: &target,
            action: &action
        )
        #expect(!refused && !undo.isEnabled && general.ran.isEmpty)
        general.isOffered = true
        keys.menuNeedsUpdate(menu)
        #expect(undo.isEnabled && menu.performKeyEquivalent(with: try AppRun.keyEvent(6, "z", .command)))
        #expect(general.ran == ["Undo"])
        let silent = SilentTarget()
        undo.target = silent
        undo.action = #selector(SilentTarget.run(_:))
        #expect(menu.performKeyEquivalent(with: try AppRun.keyEvent(6, "z", .command)) && silent.ran == ["Undo"])
    }

    /// Without a key that was matched there is nothing to run.
    @Test
    internal func nothingRunsWithoutAMatchedKey() {
        weak var released: MenuKeys?
        autoreleasepool {
            let keys = MenuKeys(kernel: kernel)
            keys.performMatched(nil)
            #expect(keys.lookups == 0 && keys.validations == 0)
            released = keys
        }
        // Nothing else keeps it.
        #expect(released == nil)
    }
}
