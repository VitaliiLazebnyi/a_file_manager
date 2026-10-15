import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Smaller things other areas asked the kernel for in review 2 (documentation/review-2/cross-requests):
/// settings keys that say what they are, broken pipes, batched tab changes and columns that can
/// give up.
@MainActor
@Suite
internal struct CrossRequestTests {
    /// Keys declared by name and by prefix are listed with their kind, single keys first; large
    /// values go where the store keeps them, by default with the rest.
    @Test
    internal func settingsKeysSayWhatTheyAre() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let keys = kernel.settingsKeys
        keys.declare("commands.user", kind: .runsCode)
        keys.declare(prefix: "findFiles.history.", kind: .history)
        keys.declare(prefix: "findFiles.", kind: .history)
        keys.declare(prefix: "findFiles.")
        keys.declare("commands.user", kind: .trust)
        // Single keys first; a key or family declared twice keeps the later word.
        #expect(keys.all.map(\.key) == ["commands.user", "findFiles.history.", "findFiles."])
        #expect(keys.all.map(\.kind) == [.trust, .history, .ordinary])
        #expect(keys.all.map(\.isPrefix) == [false, true, true])
        // Large values go where the store keeps them; by default, with the rest.
        let settings = MemorySettings()
        settings.scoped(to: "rename").setLarge(Data([9]), forKey: "undo")
        #expect(settings.largeData(forKey: "rename.undo") == Data([9]))
        #expect(settings.scoped(to: "rename").largeData(forKey: "undo") == Data([9]))
    }

    /// With a kernel made, writing to a pipe nobody reads fails instead of ending the program,
    /// and a program started from here still ends by the signal when its reader is gone.
    @Test
    internal func aBrokenPipeIsAnErrorHereAndStillEndsTheProgramsWeStart() {
        _ = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        // Writing to a pipe nobody reads fails; it does not end the program.
        // Not 0: should the pipe not be made, nothing is closed that is somebody else's.
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        let written = write(ends[1], "x", 1)
        let failure = errno
        close(ends[1])
        #expect(written == -1)
        #expect(failure == EPIPE)
        // A program started from here has the signal as the system gives it: it ends when
        // its reader is gone (a handler is not passed on; "ignore" would be).
        var pid: pid_t = 0
        let words: [String] = ["/bin/sh", "-c", "kill -PIPE $$; exit 0"]
        var arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
        arguments.append(nil)
        defer {
            for argument in arguments {
                free(argument)
            }
        }
        #expect(posix_spawn(&pid, "/bin/sh", nil, nil, &arguments, environ) == 0)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        // Ended by a signal, and that signal.
        #expect(status & 0x7F == SIGPIPE)
    }

    /// Tab changes made in a batch, nested or not, are announced once; an empty batch announces
    /// nothing, and a change outside a batch is announced on its own.
    @Test
    internal func severalChangesOfTheTabsAreAnnouncedOnce() {
        let folder = URL(fileURLWithPath: "/review2/requests")
        let tabs = PanelTabs(PanelModel(directory: folder))
        var announced = 0
        tabs.onChange = { announced += 1 }
        tabs.performBatch {
            tabs.openTab(showing: folder.appendingPathComponent("a"))
            tabs.performBatch { tabs.openTab(showing: folder.appendingPathComponent("b"), activate: false) }
            tabs.activate(0)
        }
        #expect(announced == 1)
        #expect(tabs.count == 3)
        tabs.performBatch {
            // Nothing changes.
        }
        #expect(announced == 1)
        tabs.activate(1)
        #expect(announced == 2)
    }

    /// A column whose value can be given up says so when its flag is set; a plain column asked
    /// with a set flag gives nothing, and with a clear one its value.
    @Test
    internal func aColumnCanBeToldThatItsAnswerIsNoLongerWanted() {
        let item = Fixture.file("a", in: URL(fileURLWithPath: "/review2/requests"))
        let plain = ContentColumn(id: "plain", title: "Plain") { $0.name.uppercased() }
        let patient = ContentColumn(id: "patient", title: "Patient") { entry, flag in
            flag.isCancelled ? "given up" : entry.name
        }
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(plain.value(item) == "A")
        #expect(plain.cancellableValue(item, CancellationFlag()) == "A")
        #expect(plain.cancellableValue(item, cancelled).isEmpty)
        #expect(patient.value(item) == "a")
        #expect(patient.cancellableValue(item, cancelled) == "given up")
    }
}
