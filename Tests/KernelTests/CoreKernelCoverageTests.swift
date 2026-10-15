import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// What the kernel's registries and services do with mistakes of the plugins, and the corners of
/// the kernel the rest of the suite does not reach.
@MainActor
@Suite(.serialized)
internal struct CoreKernelCoverageTests {
    /// A user interaction with only what it must offer, so that the defaults do the rest.
    private final class BareInteraction: UserInteraction {
        var answers: [Int] = []
        var rows: [FormValues] = []
        var said: [String] = []

        func prompt(_: String, value _: String, detail _: String) -> String? { nil }

        func choose(_ message: String, detail _: String, buttons _: [String], style _: QuestionStyle) -> Int {
            said.append("choose " + message)
            return answers.isEmpty ? 0 : answers.removeFirst()
        }

        func inform(_ message: String, detail _: String, style _: QuestionStyle) {
            said.append("inform " + message)
        }

        func form(_: String, detail _: String, fields _: [FormField], buttons _: [String]) -> FormValues? {
            rows.isEmpty ? nil : rows.removeFirst()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A shell that the test can let go of.
    private final class LooseShell: ShellServices {
        let bench: TestBench

        var panels: any PanelSet { bench.panels }
        var jobs: any JobService { bench.jobs }

        init(_ bench: TestBench) { self.bench = bench }

        deinit {
            // Nothing to release.
        }
    }

    /// A protocol to offer as a service.
    private protocol Probe: AnyObject {}

    /// One thing that offers `Probe`.
    private final class ProbeService: Probe {
        deinit {
            // Nothing to release.
        }
    }

    private static func kernel() -> Kernel {
        Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
    }

    /// A command registered twice keeps its first handler, and the mistake is logged as a fault.
    @Test
    internal func aCommandRegisteredTwiceKeepsItsFirstHandler() throws {
        let start = Date()
        let commands = CommandRegistry()
        let ran = Shared<[String]>([])
        commands.register(Command("core.twice", "First")) { ran.modify { $0.append("first") } }
        commands.register(Command("core.twice", "Second")) { ran.modify { $0.append("second") } }
        #expect(commands.perform("core.twice"))
        #expect(ran.value == ["first"] && commands["core.twice"]?.title == "First" && commands.all.count == 1)
        #expect(try CoreLogged.faults(containing: "core.twice", since: start).count == 1)
    }

    /// Two different menus of one title are a mistake: entries go to the first, and a fault is logged.
    @Test
    internal func twoMenusOfOneTitleBecomeTheFirst() throws {
        let start = Date()
        let menus = MenuRegistry()
        let first = MenuID("Core Menu", order: 1)
        let second = MenuID("Core Menu", order: 9)
        menus.add(["core.a"], to: MenuSection(first, order: 0))
        menus.add(["core.b"], to: MenuSection(second, order: 1))
        menus.add(["core.c"], to: MenuSection(first, order: 0))
        #expect(menus.menus.map(\.title) == ["Core Menu"])
        #expect(menus.menus.first?.items == ["core.a", "core.c", nil, "core.b"])
        #expect(try CoreLogged.faults(containing: "Core Menu", since: start).count == 1)
    }

    /// A column or a service offered twice keeps the first, and each mistake is logged.
    @Test
    internal func columnsAndServicesOfferedTwiceKeepTheFirst() throws {
        let start = Date()
        let columns = ColumnRegistry()
        columns.register(ContentColumn(id: "core.column", title: "First") { _ in "1" })
        columns.register(ContentColumn(id: "core.column", title: "Second") { _ in "2" })
        #expect(columns.all.map(\.title) == ["First"])
        let services = ServiceRegistry()
        let kept = ProbeService()
        services.register((any Probe).self, kept)
        services.register((any Probe).self, ProbeService())
        #expect(services.find((any Probe).self) === kept)
        #expect(try CoreLogged.faults(containing: "core.column", since: start).count == 1)
        #expect(try CoreLogged.faults(containing: "Probe", since: start).count == 1)
    }

    /// A file system registered twice for one scheme keeps the first.
    @Test
    internal func aSchemeRegisteredTwiceKeepsItsFirstFileSystem() throws {
        let start = Date()
        let registry = FileSystemRegistry()
        let first = MemoryFileSystem(scheme: "coretwice")
        registry.register(first)
        registry.register(MemoryFileSystem(scheme: "coretwice"))
        #expect(try registry.provider(for: first.url("/")) === first)
        #expect(try CoreLogged.faults(containing: "coretwice:", since: start).count == 1)
    }

    /// Once the shell is gone, commands that change something count as blocked.
    @Test
    internal func commandsAreBlockedWhenTheShellIsGone() {
        let kernel = Self.kernel()
        kernel.commands.register(Command("core.change", "Change")) {
            // Not run here.
        }
        let bench = TestBench(
            plugins: [],
            fileSystems: [],
            left: URL(fileURLWithPath: "/"),
            right: URL(fileURLWithPath: "/")
        )
        var shell: LooseShell? = LooseShell(bench)
        if let shell {
            kernel.attach(shell)
        }
        #expect(kernel.commands.isEnabled("core.change"))
        shell = nil
        #expect(!kernel.commands.isEnabled("core.change"))
    }

    /// A handler for broken pipes that is in place already is left alone.
    @Test
    internal func aHandlerForBrokenPipesInPlaceIsLeftAlone() {
        _ = Self.kernel()
        var before = sigaction()
        sigaction(SIGPIPE, nil, &before)
        Kernel.catchBrokenPipes()
        var after = sigaction()
        sigaction(SIGPIPE, nil, &after)
        let handler = { (action: sigaction) in unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) }
        #expect(handler(before) != 0 && handler(after) == handler(before))
    }

    /// The short ways to ask: a row that is not in the list is no row, a notice is told as a
    /// plain message, and a dismissed choice is the fallback.
    @Test
    internal func theDefaultQuestionsAnswerAsDocumented() {
        let interaction = BareInteraction()
        interaction.rows = [FormValues(values: ["row": .index(5)]), FormValues(values: ["row": .index(1)])]
        #expect(interaction.pickRow("Pick", rows: ["a", "b"]) == nil)
        #expect(interaction.pickRow("Pick", rows: ["a", "b"]) == 1)
        #expect(interaction.pickRow("Pick", rows: ["a", "b"]) == nil)
        interaction.notice("Removed")
        interaction.answers = [7, 1]
        #expect(interaction.pick("Which?", detail: "", [("One", 1), ("Two", 2)], fallback: 0) == 0)
        #expect(interaction.pick("Which?", detail: "", [("One", 1), ("Two", 2)], fallback: 0) == 2)
        #expect(interaction.said == ["inform Removed", "choose Which?", "choose Which?"])
    }

    /// A question from another thread while the main thread is busy for longer than the run loop
    /// can wait is put on the main queue as well; it is asked once, whichever way comes first.
    @Test
    internal func aQuestionWhileTheMainThreadIsBusyIsAskedOnce() async {
        let interaction = ScriptedInteraction()
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: interaction)
        let asked = Shared(0)
        let answer = Signal<Int>()
        OtherThread.start {
            answer.set(
                kernel.askUser { _ -> Int in
                    asked.modify { $0 += 1 }
                    return 42
                }
            )
        }
        // The main thread does not turn for longer than the run loop is given.
        usleep(400_000)
        var waited = 0
        while answer.wait(seconds: 0) == nil, waited < 3_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        // Whichever of the two blocks comes second finds nothing to do.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(answer.wait() == 42 && asked.value == 1)
    }
}
