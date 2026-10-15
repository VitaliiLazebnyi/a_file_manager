import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Jobs in the whole program: one after another, off the main thread, stopped, asking the user.
@MainActor
@Suite(.serialized)
internal struct AppJobTests {
    /// The program's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the program's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.programFiles)
    }

    /// Jobs run one after another off the main thread; meanwhile commands that change files wait.
    @Test
    internal func jobsRunOneAfterAnotherAndBlockChangingCommands() async {
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.cursor(app.left, on: "one.txt")
        var log: [String] = []
        let first = DispatchSemaphore(value: 0)
        app.kernel.jobs.run(
            title: "First",
            work: { _ -> String in
                first.wait()
                return "first on main: \(Thread.isMainThread)"
            },
            completion: { log.append($0) }
        )
        app.kernel.jobs.run(title: "Second", work: { _ in "second" }, completion: { log.append($0) })
        #expect(app.kernel.jobs.isBusy && log.isEmpty)
        // Commands that change files or panels wait; viewing and moving the cursor do not.
        #expect(!app.commands.isEnabled(.copy) && !app.commands.isEnabled(.goToParent))
        #expect(app.commands.isEnabled(.view) && app.commands.isEnabled(.cursorToLastEntry))
        first.signal()
        await app.settle()
        #expect(log == ["first on main: false", "second"])
        #expect(app.commands.isEnabled(.copy))
    }

    /// Cancelling everything stops the running job and the waiting one; with nothing to stop it answers at once.
    @Test
    internal func cancellingEverythingStopsRunningAndWaitingJobs() async {
        let app = await fixture.startProgram()
        defer { app.stop() }
        var log: [String] = []
        func job(_ name: String) {
            app.kernel.jobs.run(
                title: name,
                work: { monitor -> String in
                    for _ in 0..<200 where !monitor.cancellation.isCancelled {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    return monitor.cancellation.isCancelled ? "\(name) cancelled" : "\(name) finished"
                },
                completion: { log.append($0) }
            )
        }
        job("first")
        job("second")
        var idle = false
        app.shell.jobService.cancelAll { idle = true }
        #expect(!idle)
        #expect(await AppWait.until { idle })
        #expect(log == ["first cancelled", "second cancelled"] && !app.kernel.jobs.isBusy)
        var immediately = false
        app.shell.jobService.cancelAll { immediately = true }
        #expect(immediately)
    }

    /// A job asks the user from its own thread, and so does a plugin through the kernel.
    @Test
    internal func aJobCanAskTheUserFromItsOwnThread() async {
        let app = await fixture.startProgram()
        defer { app.stop() }
        let user = fixture.user
        user.choiceAnswers = [1]
        var answer = -1
        app.kernel.jobs.run(
            title: "Asking",
            work: { monitor in
                monitor.ask { user.choose("Really?", detail: "", buttons: ["Yes", "No"], style: .warning) }
            },
            completion: { answer = $0 }
        )
        await app.settle()
        #expect(answer == 1 && user.log == ["choose: Really? / "])
        // The same from a plugin that has no job at hand.
        user.choiceAnswers = [0]
        // Changed on the main thread, where the test reads it.
        nonisolated(unsafe) var viaKernel = -1
        let kernel = app.kernel
        DispatchQueue.global()
            .async {
                let result = kernel.askUser { interaction in
                    interaction.choose("Password?", detail: "", buttons: ["OK", "Cancel"], style: .information)
                }
                DispatchQueue.main.async { viaKernel = result }
            }
        #expect(await AppWait.until { viaKernel == 0 })
    }
}
