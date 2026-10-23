import AFMKernel
import Dispatch
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// The second pass of review round 2, through the real program: quitting asks the plugins and
/// waits for them where the user can see it (tools 1, archives 1, fileops 6, shell 6).
@MainActor
@Suite(.serialized)
internal struct Review2ShellP2Tests {
    /// A plugin that has a say when the program quits: it can refuse, and it can take its time
    /// finishing, until it is told or until the user does not want to wait.
    @MainActor
    private final class QuitTestPlugin: Plugin {
        let name = "QuitTest"
        var allowsQuit = true
        var asked = 0
        /// What `prepareToQuit` was handed, while it has not called its completion.
        private(set) var pending: (flag: CancellationFlag, completion: () -> Void)?
        private(set) var prepared = 0
        /// Finishes by itself as soon as it is told not to keep the user waiting.
        var givesUpWhenTold = true
        /// Finishes at once, like a plugin with nothing to write.
        var hasNothingToDo = false
        private var registration: AnyObject?

        func start(in _: Kernel) {
            // Nothing to register.
        }

        func shouldTerminate() -> Bool {
            asked += 1
            return allowsQuit
        }

        func prepareToQuit(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void) {
            prepared += 1
            guard !hasNothingToDo else {
                completion()
                return
            }
            pending = (cancellation, completion)
            if givesUpWhenTold {
                registration = cancellation.onCancel { [weak self] in
                    DispatchQueue.main.async { [weak self] in self?.finish() }
                }
            }
        }

        func finish() {
            let completion = pending?.completion
            pending = nil
            completion?()
        }

        deinit {
            // Nothing to release.
        }
    }

    private let program: PanelProgram

    /// The program's folders.
    internal init() throws {
        program = try PanelProgram(rightFile: "one.txt", contents: "old")
    }

    /// Starts the program with the standard plugins and `plugin`.
    private func start(with plugin: QuitTestPlugin) async -> PanelProgram.Running {
        await program.start(plugins: program.standardPlugins + [plugin], fileSystems: [])
    }

    /// A plugin can call the quit off before anything is stopped.
    @Test
    internal func aPluginCanCallTheQuitOffBeforeAnythingIsStopped() async {
        let plugin = QuitTestPlugin()
        let app = await start(with: plugin)
        defer { app.stop() }
        plugin.allowsQuit = false
        #expect(!app.shell.mayQuit() && plugin.asked == 1 && plugin.prepared == 0)
        plugin.allowsQuit = true
        #expect(app.shell.mayQuit() && plugin.asked == 2)
    }

    /// Quitting waits for the plugins and shows that it does, after a moment; when they are done,
    /// the program quits and the notice is gone.
    @Test
    internal func quittingWaitsForThePluginsAndShowsThatItDoes() async {
        let plugin = QuitTestPlugin()
        let app = await start(with: plugin)
        defer { app.stop() }
        var replies: [Bool] = []
        app.shell.finishToQuit(patience: 30, progressDelay: 0.05) { replies.append($0) }
        #expect(await PanelWait.until { plugin.pending != nil } && replies.isEmpty && plugin.prepared == 1)
        #expect(await PanelWait.until { app.shell.quitProgress?.isDue == true })
        #expect(
            replies.isEmpty && plugin.pending?.flag.isCancelled == false
                && app.shell.quitProgress?.text == QuitProgress.waitingText
        )
        weak let progress = app.shell.quitProgress
        plugin.finish()
        #expect(await PanelWait.until { !replies.isEmpty })
        #expect(replies == [true] && app.shell.quitProgress == nil && progress == nil)
    }

    /// Quit Now tells the plugins not to keep the user waiting.
    @Test
    internal func quitNowTellsThePluginsNotToKeepTheUserWaiting() async {
        let plugin = QuitTestPlugin()
        let app = await start(with: plugin)
        defer { app.stop() }
        var replies: [Bool] = []
        app.shell.finishToQuit(patience: 30, progressDelay: 0.01) { replies.append($0) }
        await PanelWait.until { plugin.pending != nil && app.shell.quitProgress?.isDue == true }
        let flag = plugin.pending?.flag
        app.shell.quitProgress?.pressQuitNow()
        #expect(flag?.isCancelled == true)
        #expect(await PanelWait.until { !replies.isEmpty })
        #expect(replies == [true] && plugin.pending == nil)
    }

    /// A plugin that does not even give up is not waited for for ever; its late answer changes nothing.
    @Test
    internal func aPluginThatDoesNotEvenGiveUpIsNotWaitedForForEver() async {
        let plugin = QuitTestPlugin()
        plugin.givesUpWhenTold = false
        let app = await start(with: plugin)
        defer { app.stop() }
        var replies: [Bool] = []
        app.shell.finishToQuit(patience: 0.1, progressDelay: 0.01) { replies.append($0) }
        await PanelWait.until { plugin.pending != nil && app.shell.quitProgress != nil }
        await PanelWait.pause(0.4)
        #expect(replies.isEmpty)
        app.shell.quitProgress?.pressQuitNow()
        #expect(app.shell.quitProgress?.isStopping == true && app.shell.quitProgress?.text == QuitProgress.stoppingText)
        #expect(await PanelWait.until { !replies.isEmpty })
        #expect(replies == [true] && plugin.pending?.flag.isCancelled == true)
        plugin.finish()
        await PanelWait.pause(0.1)
        #expect(replies == [true])
    }

    /// Not quitting after all leaves the program in use: jobs run again and it can be quit again.
    @Test
    internal func notQuittingAfterAllLeavesTheProgramInUse() async {
        let plugin = QuitTestPlugin()
        let app = await start(with: plugin)
        defer { app.stop() }
        var replies: [Bool] = []
        app.shell.finishToQuit(patience: 30, progressDelay: 0.01) { replies.append($0) }
        await PanelWait.until { plugin.pending != nil && app.shell.quitProgress != nil }
        // While the quit is under way, a second request is turned away.
        #expect(!app.shell.mayQuit())
        let flag = plugin.pending?.flag
        app.shell.quitProgress?.pressDontQuit()
        #expect(replies == [false] && app.shell.quitProgress == nil && flag?.isCancelled == false)
        plugin.finish()
        await PanelWait.pause(0.2)
        #expect(replies == [false] && !app.shell.jobService.isQuitting)
        var ran = false
        app.kernel.jobs.run(title: "After", work: { _ in 1 }, completion: { _ in ran = true })
        #expect(await PanelWait.until { ran } && app.shell.mayQuit())
        plugin.hasNothingToDo = true
        app.shell.finishToQuit(patience: 30, progressDelay: 5) { replies.append($0) }
        #expect(await PanelWait.until { replies.count == 2 })
        #expect(replies == [false, true] && app.shell.quitProgress == nil)
    }

    /// Quitting stops the jobs first and then lets the plugins finish.
    @Test
    internal func quittingStopsTheJobsFirstAndThenLetsThePluginsFinish() async {
        let plugin = QuitTestPlugin()
        let app = await start(with: plugin)
        defer { app.stop() }
        let stopped = Shared(false)
        app.kernel.jobs.run(
            title: "Long",
            work: { monitor in
                while !monitor.cancellation.isCancelled {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                stopped.value = true
            },
            completion: { _ in
                // The job ends when it is told to.
            }
        )
        var order: [String] = []
        app.shell.finishToQuit(patience: 30, progressDelay: 5) { order.append("reply \($0)") }
        #expect(await PanelWait.until { plugin.pending != nil })
        #expect(stopped.value && !app.kernel.jobs.isBusy && order.isEmpty)
        plugin.finish()
        #expect(await PanelWait.until { !order.isEmpty })
        #expect(order == ["reply true"])
    }
}
