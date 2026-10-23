import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The parts of the window shell that review round 2 added or changed, by themselves: the
/// program's own threads, dialogs one after the other and the keys of menus.
@MainActor
@Suite(.serialized)
internal struct PanelReview2ShellPartsTests {
    /// Stands in for the window: the target of the entries of a test menu.
    @objc
    private final class MenuTarget: NSObject, NSMenuItemValidation {
        var isOffered = true
        var validated = 0
        var senders: [NSMenuItem] = []

        func validateMenuItem(_: NSMenuItem) -> Bool {
            validated += 1
            return isOffered
        }

        @objc
        func run(_ sender: Any?) {
            if let item = sender as? NSMenuItem {
                senders.append(item)
            }
        }
    }

    /// A menu bar with a menu of commands, which holds a submenu.
    private struct Menus {
        /// The menu of the commands.
        let menu = NSMenu(title: "Commands")
        /// The submenu, which holds the one bound command.
        let inner = NSMenu(title: "More")
        /// The menu bar.
        let bar = NSMenu()
    }

    /// Makes the shared application, which menus and alerts need.
    internal init() {
        _ = NSApplication.shared
    }

    /// The URL `text` writes.
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// Registers `test_Bound` (F9 and Cmd+J) and forty other commands, all enabled as `enabled` says.
    private func registerCommands(in kernel: Kernel, enabled: @escaping () -> Bool) {
        kernel.commands.register(
            Command("test_Bound", "Bound", [.f(9), .cmd("j")]),
            enabled: enabled,
            checked: { false },
            {
                // Runs through the menu entry.
            }
        )
        for index in 0..<40 {
            kernel.commands.register(
                Command(CommandID(rawValue: "test_Other\(index)"), "Other \(index)"),
                enabled: enabled,
                checked: { false },
                {
                    // Runs through the menu entry.
                }
            )
        }
    }

    /// The menus of the kernel's commands, each entry sent to `target`: `test_Bound` in the
    /// submenu, the others and an Undo entry (Cmd+Z) in the menu.
    private func menus(of kernel: Kernel, for target: MenuTarget) -> Menus {
        let menus = Menus()
        for command in kernel.commands.all {
            let item = MenuBuilder.item(command, keys: kernel.keyBindings)
            (item.target, item.action) = (target, #selector(MenuTarget.run(_:)))
            (command.id == "test_Bound" ? menus.inner : menus.menu).addItem(item)
        }
        let undo = NSMenuItem(title: "Undo", action: #selector(MenuTarget.run(_:)), keyEquivalent: "z")
        undo.target = target
        menus.menu.addItem(undo)
        for (holder, submenu) in [
            (NSMenuItem(title: "More", action: nil, keyEquivalent: ""), menus.inner),
            (NSMenuItem(title: "Commands", action: nil, keyEquivalent: ""), menus.menu)
        ] {
            holder.submenu = submenu
            (submenu === menus.inner ? menus.menu : menus.bar).addItem(holder)
        }
        return menus
    }

    /// A lane runs one call at a time, a stuck lane holds up no other, and the threads are the
    /// kernel's, named after the lane while they work for it (S069; kernel request 1).
    @Test
    internal func aLaneRunsOneCallAtATimeAndAStuckLaneHoldsUpNoOther() async throws {
        let (stuck, other) = (try url("lane://host/stuck"), try url("lane://host/other"))
        let gate = DispatchSemaphore(value: 0)
        let log = Shared<[String]>([])
        Background.storage("test", at: stuck) {
            log.modify { $0.append("first on main: \(Thread.isMainThread), thread \(Thread.current.name ?? "")") }
            gate.wait()
        }
        Background.storage("test", at: stuck) { log.modify { $0.append("second") } }
        Background.storage("test", at: other) { log.modify { $0.append("other") } }
        // Another purpose at the same place is another lane.
        Background.storage("test2", at: stuck) { log.modify { $0.append("other purpose") } }
        #expect(await PanelWait.until { log.value.count == 3 })
        #expect(Set(log.value) == ["first on main: false, thread afm.test", "other", "other purpose"])
        gate.signal()
        #expect(await PanelWait.until { log.value.count == 4 })
        #expect(log.value.last == "second")
        let after = Shared("")
        BlockingCalls.run { after.value = Thread.current.name ?? "" }
        #expect(await PanelWait.until { !after.value.isEmpty } && after.value == "AFM.Blocking")
    }

    /// Results come back through the run loop, in order; something large is let go of elsewhere.
    @Test
    internal func resultsComeBackThroughTheRunLoopAndInOrder() async {
        var got: [Int] = []
        for number in 0..<20 {
            Background.storage("order", at: URL(fileURLWithPath: "/order"), work: { number }, then: { got.append($0) })
        }
        var computed = 0
        Background.compute(work: { (0..<1_000).reduce(0, +) }, then: { computed = $0 })
        #expect(await PanelWait.until { got.count == 20 && computed != 0 })
        #expect(got == Array(0..<20) && computed == 499_500)
        // `release` empties the variable it is given.
        var list = Optional(Array(0..<100_000))
        Background.release(&list)
        #expect(list == nil)
    }

    /// Dialogs come one after the other and not from inside the main queue.
    @Test
    internal func dialogsComeOneAfterTheOtherAndNotFromInsideTheMainQueue() async {
        var log: [String] = []
        var queued = false
        MainLoop.dialog {
            log.append("first up")
            // A dialog runs the loop itself for a while; what was sent to the main queue meanwhile arrives.
            DispatchQueue.main.async { queued = true }
            let until = Date().addingTimeInterval(5)
            while !queued, Date() < until {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            log.append("first down, queue served: \(queued)")
        }
        MainLoop.dialog { log.append("second") }
        #expect(await PanelWait.until { log.count == 3 })
        #expect(log == ["first up", "first down, queue served: true", "second"])
    }

    /// The key of a menu entry runs that entry and checks no other; a menu about to be shown
    /// brings its own entries up to date, and no other menu's (S004, S033).
    @Test
    internal func theKeyOfAMenuEntryRunsThatEntryAndChecksNoOther() throws {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        var asked = 0
        registerCommands(in: kernel) {
            asked += 1
            return true
        }
        let target = MenuTarget()
        let menus = menus(of: kernel, for: target)
        let (menu, inner, bar) = (menus.menu, menus.inner, menus.bar)
        let keys = MenuKeys(kernel: kernel)
        keys.answer(for: menu)
        let nine = String(try #require(UnicodeScalar(NSF9FunctionKey)))
        #expect(
            !bar.performKeyEquivalent(with: PanelProgram.key(0, "a", []))
                && !bar.performKeyEquivalent(with: PanelProgram.key(40, "k", .command))
        )
        #expect(keys.lookups > 0 && target.validated == 0 && asked == 0 && target.senders.isEmpty)
        #expect(bar.performKeyEquivalent(with: PanelProgram.key(101, nine, [])))
        #expect(
            target.senders.map(\.title) == ["Bound"] && target.validated == 1 && keys.validations == 1 && asked == 0
        )
        #expect(
            bar.performKeyEquivalent(with: PanelProgram.key(6, "z", .command))
                && bar.performKeyEquivalent(with: PanelProgram.key(6, "я", .command))
        )
        #expect(target.senders.map(\.title) == ["Bound", "Undo", "Undo"])
        #expect(!bar.performKeyEquivalent(with: PanelProgram.key(38, "j", .command)) && target.validated == 3)
        target.isOffered = false
        _ = bar.performKeyEquivalent(with: PanelProgram.key(101, nine, []))
        #expect(
            target.senders.count == 3 && target.validated > 3 && target.validated <= 3 + 6
                && inner.items.first?.isEnabled == false
        )
        target.isOffered = true
        var before = target.validated
        keys.menuNeedsUpdate(inner)
        #expect(target.validated == before + 1 && inner.items.first?.isEnabled == true)
        before = target.validated
        keys.menuNeedsUpdate(menu)
        #expect(target.validated == before + 41 && menu.items.allSatisfy(\.isEnabled))
    }
}
