import TestSupport
import Testing

@testable import NetworkPlugin

/// Logins of an FTP session that wait for one another: the first login's question, a password that another login
/// found meanwhile.
@Suite
internal struct CovNetFTPLogins {
    /// The answer of a server that takes the password `new` always, and `old` until `refusals` counted one.
    private static func login(_ command: String, _ line: CoverageNetworkServer.Line, refusals: CovNetCount) {
        let password = command.dropFirst("PASS ".count)
        let takes = password == "new" || (password == "old" && refusals.value == 0)
        line.send(takes ? "230 Welcome" : "530 Login incorrect")
    }

    /// A login that waits behind another one, which asks the user, ends when the session is disconnected.
    @Test
    internal func aLoginBehindOneThatAsksEndsWithTheSession() throws {
        let bench = try CovNetFTPBench { _ in
            // The usual options.
        } script: { command, line in
            guard CoverageNetworkServer.verb(command) == "USER" else {
                return .standard
            }
            line.send("331 Password")
            return .handled
        }
        bench.center.announce(ConnectionProfile(key: bench.key, user: "anna"), chosen: true)
        let (asked, answer) = (Signal<Bool>(), Signal<Bool>())
        bench.environment.askCredentials = { _, _ in
            asked.set(true)
            _ = answer.wait()
            return nil
        }
        let session = try bench.session()
        let first = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        #expect(asked.wait() == true)
        let second = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        // The second has taken a place in the pool and waits for the first login.
        #expect(Wait.until { session.connectionCount == 2 })
        session.disconnect()
        #expect(second.ended() && CovNetErrorKind(second.thrown) == .notConnected)
        answer.set(true)
        #expect(first.ended() && first.failed)
    }

    /// A first login that waits behind another one which the user gave up fails the same way, without a question.
    @Test
    internal func aLoginBehindOneTheUserGaveUpFailsTheSameWay() throws {
        let bench = try CovNetFTPBench { _ in
            // The usual options.
        } script: { command, line in
            guard CoverageNetworkServer.verb(command) == "USER" else {
                return .standard
            }
            line.send("331 Password")
            return .handled
        }
        bench.center.announce(ConnectionProfile(key: bench.key, user: "anna"), chosen: true)
        let (questions, asked, answer) = (CovNetCount(), Signal<Bool>(), Signal<Bool>())
        bench.environment.askCredentials = { _, _ in
            questions.add()
            asked.set(true)
            _ = answer.wait()
            return nil
        }
        let session = try bench.session()
        defer { session.disconnect() }
        let first = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        #expect(asked.wait() == true)
        let second = AdoptOutcome { _ = try session.connect(cancellation: nil) }
        #expect(Wait.until { session.connectionCount == 2 })
        answer.set(true)
        #expect(first.ended() && CovNetErrorKind(first.thrown) == .cancelled)
        #expect(second.ended() && CovNetErrorKind(second.thrown) == .cancelled)
        #expect(questions.value == 1 && bench.commands("PASS").isEmpty)
    }

    /// A refused login that waits behind another one, which the user gave up, is not asked about again.
    @Test
    internal func aRefusedLoginBehindOneTheUserGaveUpIsNotAskedAbout() throws {
        let (refusals, hold) = (CovNetCount(), Signal<Bool>())
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 3
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) {
            case "USER":
                line.send("331 Password")

            case "PASS":
                Self.login(command, line, refusals: refusals)

            case "SIZE":
                if command == "SIZE /slow" {
                    _ = hold.wait()
                }
                line.send("213 1")

            case "MDTM":
                line.send("213 20200101000000")

            default:
                return .standard
            }
            return .handled
        }
        bench.environment.declineMemory = 60
        bench.center.announce(ConnectionProfile(key: bench.key, user: "anna", password: "old"), chosen: true)
        let (questions, asked, answer) = (CovNetCount(), Signal<Bool>(), Signal<Bool>())
        bench.environment.askCredentials = { _, _ in
            questions.add()
            asked.set(true)
            _ = answer.wait()
            return nil
        }
        let session = try bench.session()
        _ = try session.connect(cancellation: nil)
        refusals.add()
        let busy = AdoptOutcome { _ = try session.entry(at: "/slow", cancellation: nil) }
        #expect(Wait.until { bench.server.commands.contains("SIZE /slow") })
        let others = ["/b", "/c"].map { path in AdoptOutcome { _ = try session.entry(at: path, cancellation: nil) } }
        #expect(asked.wait() == true)
        // Both were refused by the server before the user said no to the one question.
        #expect(Wait.until { bench.commands("PASS old").count == 3 })
        answer.set(true)
        #expect(others.allSatisfy { $0.ended() && $0.failed })
        #expect(questions.value == 1)
        hold.set(true)
        #expect(busy.ended() && !busy.failed)
    }

    /// A login that is refused while another is refused too takes the password the other one was given.
    @Test
    internal func aRefusedLoginTakesThePasswordAnotherWasGiven() throws {
        let (refusals, hold) = (CovNetCount(), Signal<Bool>())
        let bench = try CovNetFTPBench { values in
            values.parallelConnections = 3
        } script: { command, line in
            switch CoverageNetworkServer.verb(command) {
            case "USER":
                line.send("331 Password")

            case "PASS":
                Self.login(command, line, refusals: refusals)

            case "SIZE":
                if command == "SIZE /slow" {
                    _ = hold.wait()
                }
                line.send("213 1")

            case "MDTM":
                line.send("213 20200101000000")

            default:
                return .standard
            }
            return .handled
        }
        bench.center.announce(ConnectionProfile(key: bench.key, user: "anna", password: "old"), chosen: true)
        let (questions, asked, answer) = (CovNetCount(), Signal<Bool>(), Signal<Bool>())
        bench.environment.askCredentials = { _, _ in
            questions.add()
            asked.set(true)
            _ = answer.wait()
            return Credentials(user: "anna", password: "new")
        }
        let session = try bench.session()
        _ = try session.connect(cancellation: nil)
        // From now on the old password is refused; the one connection is busy.
        refusals.add()
        let busy = AdoptOutcome { _ = try session.entry(at: "/slow", cancellation: nil) }
        #expect(Wait.until { bench.server.commands.contains("SIZE /slow") })
        let others = ["/b", "/c"].map { path in AdoptOutcome { _ = try session.entry(at: path, cancellation: nil) } }
        #expect(asked.wait() == true)
        #expect(Wait.until { bench.commands("PASS old").count == 3 })
        answer.set(true)
        #expect(others.allSatisfy { $0.ended() && !$0.failed })
        hold.set(true)
        #expect(busy.ended() && !busy.failed)
        #expect(questions.value == 1 && bench.commands("PASS new").count == 2)
    }
}
