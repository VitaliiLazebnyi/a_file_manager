import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The whole program lets go of itself: once a started program has been stopped and nobody holds
/// it, its shell, kernel, window and panels go.
@MainActor
@Suite(.serialized)
internal struct AppShellLifetimeTests {
    /// What should go with the program.
    private struct Parts {
        weak var shell: Shell?
        weak var kernel: Kernel?
        weak var window: NSWindow?
        weak var controller: MainWindowController?
        weak var left: PanelViewController?
        weak var right: PanelViewController?
        weak var coordinator: PanelCoordinator?

        /// True once every part has gone.
        var areGone: Bool {
            shell == nil && kernel == nil && window == nil && controller == nil && left == nil && right == nil
                && coordinator == nil
        }
    }

    /// The parts of `app`, held weakly.
    private static func parts(of app: AppRun) -> Parts {
        Parts(
            shell: app.shell,
            kernel: app.kernel,
            window: app.window.window,
            controller: app.window,
            left: app.left,
            right: app.right,
            coordinator: app.shell.panelCoordinator
        )
    }

    /// The program with every standard plugin, once stopped, goes with its window and panels.
    @Test
    internal func aStoppedProgramGoesWithItsWindowAndPanels() async throws {
        let fixture = try AppFixture(files: AppFixture.programFiles)
        var parts = Parts()
        do {
            let app = await fixture.startProgram()
            app.stop()
            parts = Self.parts(of: app)
        }
        await PanelWait.drainMainQueue()
        #expect(await AppWait.until { parts.areGone })
        #expect(parts.shell == nil && parts.kernel == nil)
        #expect(parts.window == nil && parts.controller == nil)
        #expect(parts.left == nil && parts.right == nil && parts.coordinator == nil)
    }

    /// A program that was used (a folder opened, the command line and the quick filter shown, a
    /// job run, the bars checked) goes as well.
    @Test
    internal func aUsedProgramGoesAsWell() async throws {
        let fixture = try AppFixture(files: AppFixture.programFiles)
        var parts = Parts()
        do {
            let app = await fixture.startProgram()
            // What AppKit hands back autoreleased goes with the pool of each step, as the
            // program's event loop empties one after every event: the test process runs no such
            // loop on its main thread.
            autoreleasepool {
                app.cursor(app.left, on: "docs")
                app.commands.perform(.open)
            }
            await app.settle()
            var ended = false
            autoreleasepool {
                app.commands.perform(.focusCommandLine)
                app.commands.perform(.commandLineHistory)
                app.commands.perform(.quickFilter)
                app.window.validateBars()
                app.kernel.jobs.run(title: "Short", work: { _ in 1 }, completion: { _ in ended = true })
            }
            #expect(await AppWait.until { ended })
            await app.settle()
            autoreleasepool {
                app.stop()
                parts = Self.parts(of: app)
            }
        }
        await PanelWait.drainMainQueue()
        #expect(await AppWait.until { parts.areGone })
    }
}
