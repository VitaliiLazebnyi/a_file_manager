import AFMKernel
import Foundation
import TestSupport
import Testing
import os

@testable import NetworkPlugin

/// Replacing a file on a server whose rename does not replace, when a later step fails; and
/// the center of the connections at its edges.
@Suite
internal struct CoverageNetworkReplacing {
    private static let refusal = NetworkError.refused(FTPReply(code: 550, lines: ["File exists"]))
    private let server = CoverageNetworkMemoryServer()

    /// A server whose plain rename onto `/docs/b.txt` is refused.
    private func withTarget() -> (source: URL, target: URL) {
        server.session.add("/docs/b.txt", isDirectory: false, size: 7)
        return (server.url("/docs/a.txt"), server.url("/docs/b.txt"))
    }

    /// A Cancel while the file in the way is set aside ends the replacement with nothing changed.
    @Test
    internal func aCancelWhileSettingAsideChangesNothing() {
        let (source, target) = withTarget()
        let flag = CancellationFlag()
        server.session.answerRenames { renamed, target in
            if target.contains(".replaced-") {
                flag.cancel()
                throw Self.refusal
            }
            if renamed == "/docs/a.txt" {
                throw Self.refusal
            }
        }
        let error = #expect(throws: NetworkError.self) {
            try server.fileSystem.move(source, to: target, replacing: true, cancellation: flag)
        }
        #expect(CoverageNetworkServer.code(of: error) == nil && server.session.calls.last?.hasPrefix("rename") == true)
    }

    /// When neither the new file nor the old one can take the name, the error says where the old one is.
    @Test
    internal func anOldFileThatCannotGoBackIsNamed() {
        let (source, target) = withTarget()
        server.session.answerRenames { renamed, _ in
            if renamed == "/docs/a.txt" || renamed.contains(".replaced-") {
                throw Self.refusal
            }
        }
        let error = #expect(throws: NetworkError.self) {
            try server.fileSystem.move(source, to: target, replacing: true)
        }
        guard case .incomplete(let text) = error else {
            Issue.record("not incomplete: \(String(describing: error))")
            return
        }
        #expect(text.contains("it is kept on the server as /docs/.b.txt.replaced-"))
    }

    /// An old file that cannot be removed at the end stays under its other name, and the log says so.
    @Test
    internal func anOldFileThatCannotBeRemovedIsLogged() throws {
        let (source, target) = withTarget()
        let memory = server.session
        memory.answerRenames { renamed, target in
            let isFirst = !memory.calls.contains { $0.contains(".replaced-") }
            if renamed == "/docs/a.txt", target == "/docs/b.txt", isFirst {
                throw Self.refusal
            }
        }
        memory.answerRemovals { _ in throw Self.refusal }
        let lines = Signal<String>()
        server.center.environment.log = { line in lines.set(line) }
        try server.fileSystem.move(source, to: target, replacing: true)
        #expect(lines.wait()?.hasPrefix("The replaced file could not be removed") == true)
        #expect(try memory.entry(at: "/docs/b.txt", cancellation: nil)?.size == 5)
    }

    /// Without a way to make sessions, a server cannot be used.
    @Test
    internal func withoutSessionsAServerCannotBeUsed() {
        let center = ConnectionCenter(environment: SessionEnvironment())
        #expect(throws: FileSystemError.self) { try center.connect(server.key, cancellation: nil) }
    }

    /// A session that never logged in is dropped when the saved connections change.
    @Test
    internal func aSessionThatNeverLoggedInIsDropped() throws {
        server.session.isConnected = false
        _ = try server.center.session(for: server.key)
        server.center.setSaved([ConnectionProfile(key: server.key)])
        #expect(server.session.calls.contains("disconnect"))
    }

    /// Two threads that ask for the session of a server at once get the same one.
    @Test
    internal func twoThreadsGetTheSameSession() throws {
        let center = ConnectionCenter(environment: SessionEnvironment())
        let (arrived, both) = (Signal<Bool>(), Signal<Bool>())
        let calls = OSAllocatedUnfairLock(initialState: 0)
        center.makeSession = { profile, _ in
            // The first waits in the middle until the second has made its session.
            if calls.withLock({ count in
                count += 1
                return count
            }) == 1 {
                arrived.set(true)
                _ = both.wait()
            } else {
                both.set(true)
            }
            return CoverageNetworkSession(profile: profile)
        }
        let key = server.key
        let other = Signal<ObjectIdentifier>()
        Thread.detachNewThread {
            if let session = try? center.session(for: key) {
                other.set(ObjectIdentifier(session))
            }
        }
        #expect(arrived.wait() == true)
        let mine = try center.session(for: key)
        #expect(other.wait() == ObjectIdentifier(mine))
    }
}
