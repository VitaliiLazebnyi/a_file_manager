import AFMKernel
import Foundation
import TestSupport
import Testing

/// The kernel and its plugins: what a plugin adds, when commands may run, and who keeps whom alive.
@MainActor
@Suite
internal struct KernelAndPluginTests {
    /// A service a plugin offers to the others.
    private protocol Greeting {
        /// What the service says.
        var text: String { get }
    }

    /// The service as the memory plugin offers it.
    private struct English: Greeting {
        /// Always "hello".
        let text = "hello"
    }

    /// A plugin that adds one of everything a plugin can add, and logs when it starts and stops.
    private final class MemoryPlugin: Plugin {
        let name = "Memory"
        var log: [String] = []

        func start(in kernel: Kernel) {
            log.append("start")
            kernel.fileSystems.register(MemoryFileSystem())
            kernel.commands.register(Command("mem_Hello", "Hello", [.f(9)])) {
                // Its running is not the subject.
            }
            kernel.menus.add(["mem_Hello"], to: MenuSection(MenuID("Tools", order: 60), order: 10))
            kernel.services.register((any Greeting).self, English())
            kernel.openers.add { file, _ in file.name.hasSuffix(".txt") }
        }

        func stop() { log.append("stop") }

        deinit {
            // Nothing to release.
        }
    }

    /// File systems, commands with their keys, menus and services all arrive through the
    /// kernel, and the plugin is started and stopped once.
    @Test
    internal func aPluginAddsItsFeaturesThroughTheKernelOnly() throws {
        let plugin = MemoryPlugin()
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), ui: ScriptedInteraction())
        kernel.load([plugin])
        #expect(kernel.plugins.map(\.name) == ["Memory"])
        let location = try #require(URL(string: "mem:///x"))
        #expect(try kernel.fileSystems.provider(for: location).scheme == "mem")
        #expect(kernel.commands["mem_Hello"] != nil && kernel.keyBindings.command(for: .f(9)) == "mem_Hello")
        #expect(kernel.menus.menus.map(\.title) == ["Tools"])
        #expect(kernel.services.find((any Greeting).self)?.text == "hello")
        kernel.shutdown()
        #expect(plugin.log == ["start", "stop"])
    }

    /// Before a shell is attached the registry is blocked, so an enabled check that needs the
    /// panels is never asked and nothing runs.
    @Test
    internal func nothingRunsBeforeTheWindowExists() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), ui: ScriptedInteraction())
        var runs = 0
        // The enabled check would crash on kernel.panels; a blocked registry never asks it.
        kernel.commands.register(
            Command("copy", "Copy"),
            enabled: { [weak kernel] in kernel?.panels.source.model.hasOperands == true },
            { runs += 1 }
        )
        #expect(!kernel.commands.isEnabled("copy") && !kernel.commands.perform("copy") && runs == 0)
    }

    /// The shell owns the kernel; once the shell is let go, both are gone.
    @Test
    internal func theKernelGoesWithTheShell() {
        weak var kernel: Kernel?
        weak var shell: TestBench?
        do {
            let memory = MemoryFileSystem()
            let bench = TestBench(
                plugins: [MemoryPlugin()],
                fileSystems: [],
                left: memory.url("/"),
                right: memory.url("/")
            )
            (kernel, shell) = (bench.kernel, bench)
            #expect(bench.commands.isEnabled("mem_Hello"))
        }
        #expect(kernel == nil && shell == nil)
    }

    /// The user's keys from the settings replace a plugin's default keys once the shell attaches.
    @Test
    internal func theUsersKeysAreAppliedWhenTheShellAttaches() {
        let memory = MemoryFileSystem()
        let settings = MemorySettings()
        settings.set(["mem_Hello": ["f10"]], forKey: KeyBindings.settingsKey)
        let bench = TestBench(
            plugins: [MemoryPlugin()],
            fileSystems: [],
            left: memory.url("/"),
            right: memory.url("/"),
            settings: settings
        )
        #expect(bench.kernel.keyBindings.command(for: .f(10)) == "mem_Hello")
        #expect(bench.kernel.keyBindings.command(for: .f(9)) == nil)
        #expect(bench.commands.isEnabled("mem_Hello"))
    }

    /// The opener of the higher priority is asked first and may decline; without openers nothing opens.
    @Test
    internal func openersAreTriedByPriority() {
        let memory = MemoryFileSystem()
        let bench = TestBench(plugins: [], fileSystems: [memory], left: memory.url("/"), right: memory.url("/"))
        var log: [String] = []
        bench.kernel.openers.add { file, _ in
            log.append("general \(file.name)")
            return true
        }
        bench.kernel.openers.add(priority: 10) { file, _ in
            guard file.name.hasSuffix(".zip") else {
                return false
            }
            log.append("archive \(file.name)")
            return true
        }
        func file(_ name: String) -> FileItem { FileItem(url: memory.url("/" + name), name: name, isDirectory: false) }
        #expect(bench.kernel.openers.open(file("a.zip"), in: bench.left))
        #expect(bench.kernel.openers.open(file("a.txt"), in: bench.left))
        #expect(log == ["archive a.zip", "general a.txt"])
        #expect(!OpenerRegistry().open(file("a.txt"), in: bench.left))
    }
}
