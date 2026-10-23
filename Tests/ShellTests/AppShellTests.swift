import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// The window shell as the program uses it: its window, and quitting while a job does not stop.
@MainActor
@Suite(.serialized)
internal struct AppShellTests {
    /// A user who, asked whether to quit anyway, takes their time: the program goes on meanwhile
    /// (as it does under a real question's modal loop) until `isReady`, and then says no.
    internal final class SlowUser: UserInteraction {
        /// When the user answers.
        internal var isReady: () -> Bool = { true }
        /// The questions asked, in order.
        internal private(set) var asked: [String] = []

        /// Not asked in these tests.
        internal func prompt(_: String, value _: String, detail _: String) -> String? { nil }

        /// Lets the run loop work until the user is ready, then answers with the last button.
        internal func choose(_ message: String, detail _: String, buttons: [String], style _: QuestionStyle) -> Int {
            asked.append(message)
            let end = Date(timeIntervalSinceNow: Wait.ceiling)
            while !isReady(), Date() < end {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            }
            return buttons.count - 1
        }

        /// Not asked in these tests.
        internal func inform(_: String, detail _: String, style _: QuestionStyle) {
            // Nothing to show.
        }

        /// Not asked in these tests.
        internal func notice(_: String) {
            // Nothing to show.
        }

        /// Not asked in these tests.
        internal func form(_: String, detail _: String, fields _: [FormField], buttons _: [String]) -> FormValues? {
            nil
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The window's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// The main window comes on screen when asked; a command nobody has is refused silently.
    @Test
    internal func theMainWindowComesOnScreenAndUnknownCommandsAreRefused() async {
        // Nothing comes on the screen, and nothing is left open.
        // Only the program's main window: other suites' windows are theirs to close.
        let windows = StabilityWindows { $0.windowController is MainWindowController }
        defer {
            #expect(windows.shown.isEmpty && windows.open.isEmpty, "\(windows.shown) \(windows.openTitles)")
            windows.closeAll()
        }
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        var shown: [(window: NSWindow, fullScreen: Bool)] = []
        app.window.present = { shown.append(($0, $1)) }
        app.shell.showMainWindow()
        #expect(shown.count == 1 && shown.first?.window === app.window.window && shown.first?.fullScreen == false)
        #expect(!app.commands.perform("cm_NobodyHasThis"))
    }

    /// A job that ends while the user is asked whether to quit anyway is not asked about again:
    /// the program quits as soon as it has ended.
    @Test
    internal func aJobThatEndsWhileTheQuestionIsOnScreenEndsTheWaiting() async {
        let user = SlowUser()
        let kernel = Kernel(productName: StandardPlugins.productName, settings: fixture.settings, interaction: user)
        kernel.load(CorePlugins.make(pasteboard: fixture.scratch.pasteboard))
        let shell = Shell(kernel: kernel, home: fixture.box.url("home"))
        let release = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            shell.shutDown()
            kernel.shutdown()
        }
        var ended = false
        kernel.jobs.run(title: "Stuck", work: { _ in release.wait() }, completion: { _ in ended = true })
        // The question comes up; meanwhile the job ends, and then the user says to wait on.
        user.isReady = {
            release.signal()
            return ended
        }
        var replies: [Bool] = []
        shell.stopJobsToQuit(patience: 0.05) { replies.append($0) }
        #expect(await AppWait.until { !replies.isEmpty })
        #expect(replies == [true] && user.asked.count == 1 && !shell.jobService.isBusy)
    }
}
