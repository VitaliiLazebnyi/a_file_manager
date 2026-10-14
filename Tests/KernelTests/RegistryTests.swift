import AFMKernel
import Foundation
import TestSupport
import Testing

@Suite struct Commands {
    @Test func runsRegisteredCommandsWithTheirArgument() {
        let commands = CommandRegistry()
        var log: [String] = []
        commands.register(Command("plain", "Plain")) { log.append("plain") }
        commands.register(
            Command("cd", "Change Directory"),
            parameterized: { argument in
                log.append("cd \(argument.location?.path ?? argument.text ?? "-")")
            })
        #expect(commands.perform("plain"))
        #expect(commands.perform("cd", .location(URL(fileURLWithPath: "/tmp"))))
        #expect(commands.perform("cd", .text("docs")))
        #expect(commands.perform("cd"))
        #expect(log == ["plain", "cd /tmp", "cd docs", "cd -"])
        #expect(commands.all.map(\.id) == ["plain", "cd"])
        #expect(commands["plain"]?.title == "Plain")
        #expect(CommandArgument.index(3).index == 3 && CommandArgument.text("x").location == nil)
    }

    @Test func rejectsUnknownDisabledAndBlockedCommands() {
        let commands = CommandRegistry()
        var enabled = false
        var runs = 0
        var rejections = 0
        commands.onRejected = { rejections += 1 }
        commands.register(Command("copy", "Copy"), enabled: { enabled }) { runs += 1 }
        #expect(!commands.perform("unknown"))
        #expect(!commands.perform("copy"))
        enabled = true
        #expect(commands.perform("copy"))
        commands.isBlocked = { true }
        #expect(!commands.isEnabled("copy"))
        #expect(!commands.perform("copy"))
        #expect(runs == 1 && rejections == 3)
    }

    @Test func someCommandsRunWhileAJobIsInProgress() {
        let commands = CommandRegistry()
        var views = 0
        commands.register(Command("view", "View", runsDuringJobs: true)) { views += 1 }
        commands.register(Command("delete", "Delete")) {}
        commands.isBlocked = { true }
        #expect(commands.isEnabled("view") && commands.perform("view") && views == 1)
        #expect(!commands.isEnabled("delete"))
    }

    @Test func checkedState() {
        let commands = CommandRegistry()
        var hidden = false
        commands.register(Command("hidden", "Hidden Files"), checked: { hidden }) { hidden.toggle() }
        #expect(!commands.isChecked("hidden"))
        commands.perform("hidden")
        #expect(commands.isChecked("hidden"))
        #expect(!commands.isChecked("unknown"))
    }
}

@Suite struct Keys {
    @Test func shortcutsAsText() {
        let samples: [(Shortcut, String)] = [
            (.cmd("c", .shift), "shift+cmd+c"), (.f(5), "f5"), (.f(6, .shift), "shift+f6"),
            (Shortcut(.tab, .control), "ctrl+tab"),
            (Shortcut(.left, .option), "opt+left"), (Shortcut(.keypadPlus), "num+"),
            (Shortcut(.keypadPlus, .control), "ctrl+num+"),
            (.cmd("="), "cmd+="), (.cmd("+"), "cmd++"), (Shortcut(.space), "space"),
            (Shortcut(.forwardDelete, .shift), "shift+delete")
        ]
        for (shortcut, text) in samples {
            #expect(shortcut.notation == text)
            #expect(Shortcut(notation: text) == shortcut)
        }
        #expect(Shortcut(notation: "CMD+Shift+C") == .cmd("c", .shift))
        #expect(Shortcut(notation: "cmd+shift+c") == Shortcut(notation: "shift+cmd+c"))
        #expect(
            Shortcut(notation: "f13") == nil && Shortcut(notation: "") == nil
                && Shortcut(notation: "cmd+nonsense") == nil)
    }

    @Test func commandsBringTheirDefaultKeys() {
        let keys = KeyBindings()
        let commands = CommandRegistry(keyBindings: keys)
        commands.register(Command("copy", "Copy", [.f(5), .cmd("k")])) {}
        commands.register(Command("view", "View", [.f(3)])) {}
        #expect(keys.command(for: .f(5)) == "copy" && keys.command(for: .cmd("k")) == "copy")
        #expect(keys.shortcuts(for: "copy") == [.f(5), .cmd("k")])
        #expect(keys.command(for: .f(9)) == nil && keys.conflicts.isEmpty)
    }

    @Test func aKeyTakenTwiceStaysWithTheFirstAndIsReported() {
        let keys = KeyBindings()
        keys.bindDefault(.f(5), to: "copy")
        keys.bindDefault(.f(5), to: "pack")
        keys.bindDefault(.f(5), to: "copy")
        #expect(keys.command(for: .f(5)) == "copy")
        #expect(keys.conflicts == [KeyBindings.Conflict(shortcut: .f(5), kept: "copy", rejected: "pack")])
        #expect(keys.shortcuts(for: "pack").isEmpty)
    }

    @Test func theUsersBindingsReplaceTheDefaults() {
        let keys = KeyBindings()
        keys.bindDefault(.f(5), to: "copy")
        keys.bindDefault(.cmd("k"), to: "copy")
        keys.bindDefault(.f(6), to: "move")
        let settings = MemorySettings()
        settings.set(["move": ["f5", "ctrl+m", "nonsense+"], "view": ["f6"]], forKey: KeyBindings.settingsKey)
        keys.load(from: settings)
        // Move takes F5 away from Copy and gives up F6, which View takes; Copy keeps its other key.
        #expect(keys.command(for: .f(5)) == "move" && keys.command(for: Shortcut(.character("m"), .control)) == "move")
        #expect(keys.shortcuts(for: "move") == [.f(5), Shortcut(.character("m"), .control)])
        #expect(keys.shortcuts(for: "copy") == [.cmd("k")])
        #expect(keys.command(for: .f(6)) == "view")
    }
}

@Suite struct Menus {
    static let files = MenuID("Files", order: 10), show = MenuID("Show", order: 50)

    @Test func menusAreOrderedAndGrouped() {
        let menus = MenuRegistry()
        menus.add(["sort"], to: MenuSection(Menus.show, order: 10))
        menus.add(["copy", "move"], to: MenuSection(Menus.files, order: 20))
        menus.add(["open"], to: MenuSection(Menus.files, order: 10))
        menus.add(["view"], to: MenuSection(Menus.files, order: 10))
        menus.add(["delete"], to: MenuSection(Menus.files, order: 40))
        #expect(menus.menus.map(\.title) == ["Files", "Show"])
        #expect(menus.menus[0].items == ["open", "view", nil, "copy", "move", nil, "delete"])
    }

    @Test func contextMenuLeavesOutItemEntriesOnEmptySpace() {
        let menus = MenuRegistry()
        menus.addToContextMenu(["open"], in: ContextMenuSection(order: 10), onItemOnly: true)
        menus.addToContextMenu(["paste"], in: ContextMenuSection(order: 20))
        menus.addToContextMenu(["copy"], in: ContextMenuSection(order: 20), onItemOnly: true)
        #expect(menus.contextMenu(onItem: true) == ["open", nil, "paste", "copy"])
        #expect(menus.contextMenu(onItem: false) == ["paste"])
    }
}

@MainActor @Suite struct KernelAndPlugins {
    final class MemoryPlugin: Plugin {
        let name = "Memory"
        var log: [String] = []

        func start(in kernel: Kernel) {
            log.append("start")
            kernel.fileSystems.register(MemoryFileSystem())
            kernel.commands.register(Command("mem_Hello", "Hello", [.f(9)])) {}
            kernel.menus.add(["mem_Hello"], to: MenuSection(MenuID("Tools", order: 60), order: 10))
            kernel.services.register(Greeting.self, English())
            kernel.openers.add { file, _ in file.name.hasSuffix(".txt") }
        }

        func stop() { log.append("stop") }
    }

    protocol Greeting { var text: String { get } }
    struct English: Greeting { let text = "hello" }

    @Test func aPluginAddsItsFeaturesThroughTheKernelOnly() throws {
        let plugin = MemoryPlugin()
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), ui: ScriptedInteraction())
        kernel.load([plugin])
        #expect(kernel.plugins.map(\.name) == ["Memory"])
        #expect(try kernel.fileSystems.provider(for: URL(string: "mem:///x")!).scheme == "mem")
        #expect(kernel.commands["mem_Hello"] != nil && kernel.keyBindings.command(for: .f(9)) == "mem_Hello")
        #expect(kernel.menus.menus.map(\.title) == ["Tools"])
        #expect(kernel.services.find(Greeting.self)?.text == "hello")
        kernel.shutdown()
        #expect(plugin.log == ["start", "stop"])
    }

    @Test func nothingRunsBeforeTheWindowExists() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), ui: ScriptedInteraction())
        var runs = 0
        // The enabled check would crash on kernel.panels; a blocked registry never asks it.
        kernel.commands.register(Command("copy", "Copy"), enabled: { kernel.panels.source.model.hasOperands }) {
            runs += 1
        }
        #expect(!kernel.commands.isEnabled("copy") && !kernel.commands.perform("copy") && runs == 0)
    }

    @Test func theUsersKeysAreAppliedWhenTheShellAttaches() {
        let memory = MemoryFileSystem()
        let settings = MemorySettings()
        settings.set(["mem_Hello": ["f10"]], forKey: KeyBindings.settingsKey)
        let bench = TestBench(
            plugins: [MemoryPlugin()], fileSystems: [], left: memory.url("/"), right: memory.url("/"),
            settings: settings)
        #expect(
            bench.kernel.keyBindings.command(for: .f(10)) == "mem_Hello"
                && bench.kernel.keyBindings.command(for: .f(9)) == nil)
        #expect(bench.commands.isEnabled("mem_Hello"))
    }

    @Test func openersAreTriedByPriority() {
        let memory = MemoryFileSystem()
        let bench = TestBench(plugins: [], fileSystems: [memory], left: memory.url("/"), right: memory.url("/"))
        var log: [String] = []
        bench.kernel.openers.add { file, _ in
            log.append("general \(file.name)")
            return true
        }
        bench.kernel.openers.add(priority: 10) { file, _ in
            guard file.name.hasSuffix(".zip") else { return false }
            log.append("archive \(file.name)")
            return true
        }
        func file(_ name: String) -> FileItem { FileItem(url: memory.url("/" + name), name: name, isDirectory: false) }
        #expect(bench.kernel.openers.open(file("a.zip"), in: bench.left))
        #expect(bench.kernel.openers.open(file("a.txt"), in: bench.left))
        #expect(log == ["archive a.zip", "general a.txt"])
        #expect(!OpenerRegistry().open(file("a.txt"), in: bench.left))
    }

    @Test func unknownSchemesHaveNoProvider() {
        let fileSystems = FileSystemRegistry()
        #expect(throws: FileSystemError.self) { try fileSystems.provider(for: URL(fileURLWithPath: "/tmp")) }
        #expect(fileSystems.item(at: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func readsTypedLocations() {
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        let base = memory.url("/work/docs")
        #expect(
            fileSystems.location(from: "sub/a.txt", relativeTo: base).isSameLocation(
                as: memory.url("/work/docs/sub/a.txt")))
        #expect(fileSystems.location(from: "..", relativeTo: base).isSameLocation(as: memory.url("/work")))
        #expect(fileSystems.location(from: "/top", relativeTo: base).isSameLocation(as: memory.url("/top")))
        #expect(fileSystems.location(from: "", relativeTo: base).isSameLocation(as: base))
        #expect(
            fileSystems.location(from: "mem:///other/place", relativeTo: URL(fileURLWithPath: "/tmp")).isSameLocation(
                as: memory.url("/other/place")))
        let local = URL(fileURLWithPath: "/tmp")
        #expect(fileSystems.location(from: "/usr/bin", relativeTo: local).path == "/usr/bin")
        #expect(fileSystems.location(from: "~/x", relativeTo: local).path == NSHomeDirectory() + "/x")
        // Each file system writes its own locations for the user.
        #expect(fileSystems.displayPath(base) == "mem:/work/docs")
        #expect(fileSystems.displayPath(URL(string: "ftp://host/x")!) == "ftp://host/x")
        // What a file system writes for the user, it reads back: dialogs propose targets this way.
        #expect(
            fileSystems.location(from: fileSystems.displayPath(base) + "/new.txt", relativeTo: local)
                .isSameLocation(as: memory.url("/work/docs/new.txt")))
        #expect(fileSystems.location(from: "mem:/top/*.*", relativeTo: local).path == "/top/*.*")
    }

    @Test func settingsValuesAndScopes() {
        let settings = MemorySettings()
        #expect(settings.value([String].self, forKey: "list") == nil)
        settings.set(["a", "b"], forKey: "list")
        #expect(settings.value([String].self, forKey: "list") == ["a", "b"])
        let viewer = settings.scoped(to: "viewer")
        let search = settings.scoped(to: "search")
        viewer.set(12, forKey: "fontSize")
        #expect(viewer.value(Int.self, forKey: "fontSize") == 12)
        #expect(search.value(Int.self, forKey: "fontSize") == nil)
        #expect(settings.value(Int.self, forKey: "viewer.fontSize") == 12)
    }
}

@Suite struct Concurrency {
    @Test func parallelMapKeepsTheOrder() {
        let input = Array(0..<10_000)
        #expect(Parallel.map(input) { $0 * 2 } == input.map { $0 * 2 })
        #expect(Parallel.map([Int]()) { $0 } == [])
        #expect(Parallel.map([7]) { "\($0)" } == ["7"])
        #expect(Parallel.map(Array(0..<10), serialBelow: 100) { $0 + 1 } == Array(1...10))
    }

    @Test func parallelMapUsesSeveralThreads() {
        let lock = NSLock()
        var threads: Set<UInt64> = []
        // The threads are shared with whatever else runs at the time (other tests keep them
        // busy, and the oldest job is served first), so a second one is waited for.
        let deadline = Date().addingTimeInterval(30)
        _ = Parallel.map(Array(0..<64)) { _ -> Int in
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            lock.lock()
            threads.insert(id)
            lock.unlock()
            while ProcessInfo.processInfo.activeProcessorCount > 1, Date() < deadline {
                lock.lock()
                let isShared = threads.count > 1
                lock.unlock()
                if isShared { break }
                Thread.sleep(forTimeInterval: 0.002)
            }
            return 0
        }
        #expect(threads.count > 1 || ProcessInfo.processInfo.activeProcessorCount == 1)
    }

    @Test func aCancellationFlagIsSeenFromEveryThread() {
        let flag = CancellationFlag()
        #expect(!flag.isCancelled)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            if index == 3 { flag.cancel() }
            _ = flag.isCancelled
        }
        #expect(flag.isCancelled)
    }

    @Test func jobProgressChoosesBytesOrItems() {
        let copying = JobProgress(
            lines: ["From: a", "To: b"], itemsDone: 1, itemsTotal: 4, bytesDone: 250, bytesTotal: 1000)
        #expect(
            copying.measuresBytes && copying.amountDone == 250 && copying.amountTotal == 1000
                && copying.fraction == 0.25)
        let deleting = JobProgress(lines: ["Deleting: a"], itemsDone: 1, itemsTotal: 4)
        #expect(
            !deleting.measuresBytes && deleting.amountDone == 1 && deleting.amountTotal == 4
                && deleting.fraction == 0.25)
    }
}
