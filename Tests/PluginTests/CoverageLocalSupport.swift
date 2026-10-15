import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// The local file system's helpers: signals that end calls, links into places that do not answer.
@Suite
internal struct CoverageLocalSupport {
    /// A call ended by a signal nobody sent is made again.
    @Test
    internal func aCallEndedByASignalNobodySentIsMadeAgain() throws {
        let interruption = Interruption()
        var calls = 0
        let result = try interruption.run {
            calls += 1
            if calls == 1 {
                errno = EINTR
                return -1
            }
            return 7
        }
        #expect(result == 7 && calls == 2)
    }

    /// A call that ignores the signal is sent it again until it is over.
    @Test
    internal func aCallThatIgnoresTheSignalIsSentItAgainUntilItIsOver() {
        let interruption = Interruption()
        let inside = Signal<Bool>()
        let done = Signal<Int>()
        Thread.detachNewThread {
            let result = try? interruption.run {
                inside.set(true)
                // Deaf to the signal for a while: each one only cuts a sleep short.
                let end = Date(timeIntervalSinceNow: 0.35)
                while Date() < end { usleep(10_000) }
                return 3
            }
            done.set(result ?? -1)
        }
        #expect(inside.wait() == true)
        interruption.interrupt()
        #expect(done.wait() == 3)
        #expect(interruption.isInterrupted)
    }

    /// The signal is sent fifty times at most.
    @Test
    internal func theSignalIsSentFiftyTimesAtMost() {
        let interruption = Interruption()
        let inside = Signal<Bool>()
        let done = Signal<Int>()
        Thread.detachNewThread {
            let result = try? interruption.run {
                inside.set(true)
                let end = Date(timeIntervalSinceNow: 5.4)
                while Date() < end { usleep(20_000) }
                return 1
            }
            done.set(result ?? -1)
        }
        #expect(inside.wait() == true)
        interruption.interrupt()
        #expect(done.wait() == 1)
    }

    /// What is not a link or points nowhere readable is asked about on its own thread.
    @Test
    internal func whatIsNotALinkOrPointsNowhereReadableIsAskedAboutOnItsOwnThread() throws {
        let box = try Sandbox()
        let file = try box.file("plain.txt", "123")
        let resolver = LinkResolver()
        #expect(resolver.resolve(file.path)?.size == 3)
        // A link whose text is not UTF-8.
        let link = box.url("odd-link")
        let made = link.path.withCString { path in symlink([CChar(bitPattern: 0xFF), 0], path) }
        #expect(made == 0)
        #expect(resolver.resolve(link.path) == nil)
    }

    /// Links into a place that does not answer are given up and at most eight are asked.
    @Test
    internal func linksIntoAPlaceThatDoesNotAnswerAreGivenUpAndAtMostEightAreAsked() throws {
        let box = try Sandbox()
        let link = box.url("to-share")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/System/Volumes/Data/home/afm-coverage"
        )
        let gate = CoverageCoreGate()
        let resolver = LinkResolver(patience: 0.05) { _ in
            gate.pass()
            return LinkTarget(isDirectory: true, isRegular: false, size: 0)
        }
        for _ in 0..<LinkResolver.limit { #expect(resolver.resolve(link.path) == nil) }
        // Eight questions are stuck: the next is not asked at all.
        #expect(resolver.resolve(link.path) == nil)
        gate.open()
        #expect(Wait.until(seconds: 60) { resolver.resolve(link.path)?.isDirectory == true })
    }
}
