import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The end of a program that comes back when the runner that started it is gone.
@MainActor
@Suite
internal struct SweepCommandRunnerTests {
    /// The blocks the runner handed back to the main thread, kept to be run by the test.
    private final class Kept: @unchecked Sendable {
        // Guarded by `lock`.
        private let lock = NSLock()
        private var blocks: [@MainActor @Sendable () -> Void] = []

        var count: Int { lock.withLock { blocks.count } }

        func keep(_ block: @escaping @MainActor @Sendable () -> Void) {
            lock.withLock { blocks.append(block) }
        }

        func takeAll() -> [@MainActor @Sendable () -> Void] {
            lock.withLock {
                defer { blocks = [] }
                return blocks
            }
        }
    }

    /// A program that ended after its runner went tells nothing.
    @Test
    internal func aProgramThatEndsAfterItsRunnerWentTellsNothing() async throws {
        let box = try Sandbox()
        try box.folder("A")
        let bench = TestBench(
            plugins: [NavigationPlugin()],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("A")
        )
        let kept = Kept()
        weak var gone: CommandRunner?
        do {
            let runner = CommandRunner(
                kernel: bench.kernel,
                launchesApplications: true,
                background: nil,
                listFolder: box.url("lists")
            )
            runner.backToMain = { kept.keep($0) }
            gone = runner
            // A file that is no program: the shell says so at once, and the runner would tell.
            runner.run(CommandAction(command: "/etc/hosts"), title: "Hosts")
            #expect(await AppWait.until { kept.count == 1 })
        }
        #expect(gone == nil)
        for block in kept.takeAll() { block() }
        #expect(bench.interaction.log.isEmpty)
    }
}
