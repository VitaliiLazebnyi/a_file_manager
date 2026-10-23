import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The real kernel, the standard plugins and the real window shell, started without showing
/// anything and driven through commands and key presses.
///
/// The parts have their own tests; the tests in the extensions of this suite check that they
/// work together, including everything that happens across threads. The folders and stand-ins
/// are those of `AppFixture` with its program files.
@MainActor
@Suite(.serialized)
internal struct Application {
    /// A started program, and what the tests reach into.
    internal typealias Running = AppRun

    /// The program's folders and stand-ins.
    internal let fixture: AppFixture

    /// The folders on disk.
    internal var box: Sandbox { fixture.box }
    /// A file system in memory, registered when the program starts.
    internal var memory: MemoryFileSystem { fixture.memory }
    /// The user, as the test scripts them.
    internal var user: ScriptedInteraction { fixture.user }
    /// The settings the program keeps.
    internal var settings: MemorySettings { fixture.settings }
    /// A pasteboard of the test's own.
    internal var scratch: ScratchPasteboard { fixture.scratch }

    /// A sandbox with the program's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.programFiles)
    }

    /// Waits, with the main thread free to work, until `condition` holds; false when it still
    /// does not after `seconds`.
    @discardableResult
    internal func wait(upTo seconds: TimeInterval, until condition: () -> Bool) async -> Bool {
        await AppWait.until(seconds: seconds, condition)
    }

    /// Waits, with the main thread free to work, until `condition` holds; false on a hang.
    @discardableResult
    internal func wait(until condition: () -> Bool) async -> Bool {
        await AppWait.until(condition)
    }

    /// The whole program, once its panels have been read.
    internal func start() async -> Running {
        await fixture.startProgram()
    }

    /// Waits until nothing is being read and no job is running.
    internal func settle(_ app: Running) async {
        await app.settle()
    }

    /// Presses the key `keyCode` in the source panel; true when it was used.
    internal func press(_ app: Running, _ keyCode: UInt16) -> Bool {
        (try? app.press(keyCode, [])) == true
    }
}
