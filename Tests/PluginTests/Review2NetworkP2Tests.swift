import AFMKernel
import Foundation
@testable import NetworkPlugin
import Security
import TestSupport
import Testing

/// A lock-guarded list for what stand-ins record from several threads.
private final class Record<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func add(_ value: Value) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Value] { lock.lock(); defer { lock.unlock() }; return values }
}

/// The background work of one server never waits behind that of another (second pass: the
/// cause of network tests that failed when they ran beside a test with a server that is dead).
@Suite struct Review2NetworkP2Background {
    private final class Lane {}

    @Test func aLaneThatIsStuckHoldsUpOnlyItself() {
        let (stuck, free) = (Lane(), Lane())
        let release = DispatchSemaphore(value: 0)
        let started = Record<Int>()
        // Far more pieces than the lane may run at once, none of which ends by itself.
        let pieces = Background.mostPerLane * 4
        for index in 0..<pieces {
            Background.run(lane: stuck) {
                started.add(index)
                release.wait()
            }
        }
        // The other lane's work gets through all the same, however long this takes to be seen.
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<5 { Background.run(lane: free) { done.signal() } }
        for _ in 0..<5 { #expect(done.wait(timeout: .now() + 300) == .success) }
        #expect(Background.waitUntilIdle(lane: free, timeout: 300))
        // Of the stuck lane only so many run, and the wait for it says it is not done.
        #expect(started.all.count <= Background.mostPerLane)
        #expect(!Background.waitUntilIdle(lane: stuck, timeout: 0.2))
        #expect(Background.threadCount <= Background.mostThreads)
        // Let go, every piece runs, in the order it was queued within what ran together.
        for _ in 0..<pieces { release.signal() }
        #expect(Background.waitUntilIdle(lane: stuck, timeout: 300))
        #expect(started.all.sorted() == Array(0..<pieces))
    }

    @Test func aDeadServerDoesNotKeepAnotherServersConnectionFromComingBack() throws {
        // One server that never sends a byte of a file, with readers dropped in the middle:
        // each waits in the background for an answer that does not come.
        var dead = TestFTPServer.Options()
        dead.stallRETR = true
        let stalled = try FTPFixture(dead) {
            $0.parallelConnections = 8
            $0.timeout = 600
        }
        try stalled.box.file("srv/f.bin", "zzzz")
        var abandoned: [AdoptOutcome] = []
        for _ in 0..<8 {
            var reader: FileReader? = try stalled.fileSystem.read(stalled.url("/f.bin"))
            let pending = reader
            abandoned.append(AdoptOutcome { _ = try pending?.read(upToCount: 10) })
            #expect(adoptWait(120) { stalled.server.commands.filter { $0.hasPrefix("RETR") }.count == abandoned.count })
            reader?.interrupt()
            reader = nil
        }
        // Meanwhile another server is used as usual, and its connection comes back at once.
        let fixture = try FTPFixture { $0.parallelConnections = 1 }
        try Data(repeating: 7, count: 2_000_000).write(to: fixture.box.url("srv/big.bin"))
        for _ in 0..<4 {
            let reader = try fixture.fileSystem.read(fixture.url("/big.bin"))
            #expect(try reader.read(upToCount: 100)?.count == 100)
            reader.close()
            #expect(fixture.settle(timeout: 120), "the connection of a healthy server waited behind a dead one")
        }
        #expect(try fixture.names("/") == ["big.bin"])
        stalled.center.disconnectAll()
        stalled.server.stop()
        for outcome in abandoned { #expect(outcome.ended(within: 120)) }
    }
}

/// The calls that change something end on the caller's flag (N010, N026; kernel API of the
/// first pass: `createDirectory`, `remove`, `move`, `setAttributes` with `cancellation`).
@Suite struct Review2NetworkP2Cancelling {
    /// A fixture whose first login sits at its password question until `answer` is signalled.
    private func heldAtLogin() throws -> (fixture: FTPFixture, answer: DispatchSemaphore, first: AdoptOutcome) {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options) { $0.timeout = 600 }
        try fixture.box.file("srv/a.txt", "a")
        try fixture.box.folder("srv/d")
        fixture.center.announce(ConnectionProfile(key: fixture.key, user: "anna"), chosen: true)
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return Credentials(user: "anna", password: "pw")
        }
        let first = AdoptOutcome { _ = try fixture.names("/") }
        #expect(asked.wait(timeout: .now() + 120) == .success)
        return (fixture, answer, first)
    }

    @Test func everyChangingCallOfAnFTPServerLeavesAWaitWhenItsFlagIsSet() throws {
        let (fixture, answer, first) = try heldAtLogin()
        let fs = fixture.fileSystem
        let calls: [(String, (CancellationFlag) throws -> Void)] = [
            ("createDirectory", { try fs.createDirectory(at: fixture.url("/made"), cancellation: $0) }),
            ("remove", { try fs.remove(fixture.url("/a.txt"), cancellation: $0) }),
            ("move", { try fs.move(fixture.url("/a.txt"), to: fixture.url("/b.txt"), replacing: true, cancellation: $0) }),
            ("setAttributes", { try fs.setAttributes(FileAttributes(permissions: 0o600), of: fixture.url("/a.txt"), cancellation: $0) }),
        ]
        // All four wait behind the login, which nothing ends; each is ended by its own flag
        // alone. No time limit helps them here: the timeout is ten minutes.
        let waits = calls.map { name, call -> (String, CancellationFlag, AdoptOutcome) in
            let flag = CancellationFlag()
            return (name, flag, AdoptOutcome { try call(flag) })
        }
        for (name, flag, outcome) in waits {
            #expect(!outcome.ended(within: 0.3), "\(name) did not wait")
            flag.cancel()
            #expect(outcome.ended(within: 120) && outcome.failed, "\(name) did not end when it was cancelled")
        }
        // Nothing was changed, and the session is as good as before.
        answer.signal()
        #expect(first.ended(within: 120) && !first.failed)
        #expect(try fixture.names("/") == ["a.txt", "d"])
        #expect(!fixture.server.commands.contains { $0.hasPrefix("MKD") || $0.hasPrefix("DELE") || $0.hasPrefix("RNFR") || $0.hasPrefix("SITE") })
        // A flag that is set before the call: nothing is asked of the server at all.
        let set = CancellationFlag()
        set.cancel()
        let before = fixture.server.commands.count
        for (_, call) in calls { #expect(throws: (any Error).self) { try call(set) } }
        #expect(fixture.server.commands.count == before)
        // And with a flag that is never set they do their work.
        let unset = CancellationFlag()
        try fs.createDirectory(at: fixture.url("/made/deeper"), cancellation: unset)
        try fs.move(fixture.url("/a.txt"), to: fixture.url("/made/b.txt"), replacing: false, cancellation: unset)
        try fs.setAttributes(FileAttributes(permissions: 0o600), of: fixture.url("/made/b.txt"), cancellation: unset)
        #expect(fixture.box.read("srv/made/b.txt") == "a")
        try fs.remove(fixture.url("/made/b.txt"), cancellation: unset)
        try fs.remove(fixture.url("/made/deeper"), cancellation: unset)
        #expect(try fixture.names("/made").isEmpty)
    }

    @Test func aChangingCallOnASecureShellServerThatDoesNotAnswerEndsOnItsFlag() throws {
        let environment = SessionEnvironment()
        var values = NetworkOptions.Values()
        values.timeout = 600
        environment.options.values = values
        // A "server" that never says a word: the login never ends, and every call waits behind it.
        let center = ConnectionCenter(environment: environment)
        center.makeSession = { profile, environment in
            SFTPSession(profile: profile, environment: environment, transport: SFTPTransport(executable: "/bin/sleep", arguments: ["600"]))
        }
        let key = ServerKey(scheme: "sftp", host: "silent.invalid")
        center.noteChosen(key)
        defer { center.disconnectAll() }
        let fs = RemoteFileSystem(scheme: "sftp", center: center)
        let calls: [(String, (CancellationFlag) throws -> Void)] = [
            ("createDirectory", { try fs.createDirectory(at: key.url(path: "/made"), cancellation: $0) }),
            ("remove", { try fs.remove(key.url(path: "/a.txt"), cancellation: $0) }),
            ("move", { try fs.move(key.url(path: "/a.txt"), to: key.url(path: "/b.txt"), replacing: true, cancellation: $0) }),
            ("setAttributes", { try fs.setAttributes(FileAttributes(permissions: 0o600), of: key.url(path: "/a.txt"), cancellation: $0) }),
        ]
        for (name, call) in calls {
            let flag = CancellationFlag()
            let outcome = AdoptOutcome { try call(flag) }
            #expect(!outcome.ended(within: 0.3), "\(name) did not wait")
            flag.cancel()
            #expect(outcome.ended(within: 120) && outcome.failed, "\(name) did not end when it was cancelled")
        }
    }

    @Test func aRequestThatIsNeverAnsweredEndsOnTheFlag() throws {
        guard FakeSFTPServer.isAvailable else { return }
        // Logged in, and the server answers everything but the question about this one path.
        let suite = try NetworkFixSFTP(mode: .hangingStat, timeout: 600)
        try Data("x".utf8).write(to: suite.box.url("srv/hang"))
        _ = try suite.center.session(for: suite.key).connect(cancellation: nil)
        // Nothing is remembered of the folder: removing asks what the path is, and waits.
        let fresh = suite.fileSystem
        let flag = CancellationFlag()
        let outcome = AdoptOutcome { try fresh.remove(suite.url("/hang"), cancellation: flag) }
        #expect(!outcome.ended(within: 0.5))
        flag.cancel()
        #expect(outcome.ended(within: 120) && outcome.failed)
        #expect(suite.box.exists("srv/hang"))
        suite.center.disconnectAll()
    }

    @Test func eitherFlagEndsTheWaitAndNothingIsLeftRegistered() {
        let (own, callers) = (CancellationFlag(), CancellationFlag())
        // The caller's flag.
        withEither(own, callers) { both in
            #expect(!both.isCancelled)
            callers.cancel()
            #expect(both.isCancelled)
        }
        // The session's own, and a flag that was set before.
        let second = CancellationFlag()
        withEither(own, second) { both in
            own.cancel()
            #expect(both.isCancelled)
        }
        withEither(own, CancellationFlag()) { #expect($0.isCancelled) }
        // Without a caller's flag the session's own is used as it is.
        let alone = CancellationFlag()
        withEither(alone, nil) { #expect($0 === alone) }
        // After the call nothing of it hangs on the flags: a later cancel reaches no stale flag.
        let (long, short) = (CancellationFlag(), CancellationFlag())
        weak var made: CancellationFlag?
        withEither(long, short) { made = $0 }
        #expect(made == nil)
        long.cancel()
    }
}

/// An address the user typed is not asked about (N071; `ServerConsentService` of the kernel).
@Suite struct Review2NetworkP2Consent {
    @Test func aServerTheUserNamedInPersonIsNotAskedAbout() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/a.txt", "a")
        let asked = Record<ServerKey>()
        fixture.environment.askToConnect = { profile in
            asked.add(profile.key)
            return false
        }
        // An address that merely stood somewhere: asked, and No is no connection.
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(asked.all == [fixture.key])
        // Typed by the user: the same server connects without a question.
        TypedAddresses(center: fixture.center).userChose(fixture.url("/pub/whatever"))
        #expect(try fixture.names("/") == ["a.txt"])
        #expect(asked.all == [fixture.key])
        // After Disconnect the consent is gone with the connection.
        fixture.center.disconnect(fixture.key)
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(asked.all.count == 2)
    }

    @Test func theTopOfAServerIsKnownFromTheAddressAlone() throws {
        let center = ConnectionCenter(environment: SessionEnvironment())
        let fs = RemoteFileSystem(scheme: "sftp", center: center)
        let key = ServerKey(scheme: "sftp", host: "files.example.com", port: 2222)
        let deep = key.url(path: "/" + Array(repeating: "d", count: 3000).joined(separator: "/"))
        // The same answer as climbing with `parent(of:)`, without the climb, and without a connection.
        var climbed = deep
        while let parent = fs.parent(of: climbed) { climbed = parent }
        #expect(fs.root(of: deep) == climbed && fs.root(of: deep) == key.url())
        #expect(fs.root(of: key.url()) == key.url())
        #expect(fs.connectsToServer)
        #expect(!center.isConnected(key))
    }

    @Test func otherLocationsSayNothing() throws {
        let fixture = try FTPFixture()
        let asked = Record<ServerKey>()
        fixture.environment.askToConnect = { profile in
            asked.add(profile.key)
            return false
        }
        let consent = TypedAddresses(center: fixture.center)
        consent.userChose(URL(fileURLWithPath: "/tmp"))
        consent.userChose(URL(string: "smb://127.0.0.1:\(fixture.server.port)/share")!)
        // Another port of the same host is another server.
        consent.userChose(ServerKey(scheme: "ftp", host: "127.0.0.1", port: fixture.server.port == 21 ? 2121 : 21).url(path: "/"))
        #expect(throws: (any Error).self) { _ = try fixture.names("/") }
        #expect(asked.all == [fixture.key])
    }

    @Test func aLoginThatIsUnderWayIsNotDroppedByTheNews() throws {
        var options = TestFTPServer.Options()
        (options.user, options.password) = ("anna", "pw")
        let fixture = try FTPFixture(options)
        fixture.center.announce(ConnectionProfile(key: fixture.key, user: "anna"), chosen: true)
        let (asked, answer) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        fixture.environment.askCredentials = { _, _ in
            asked.signal()
            answer.wait()
            return Credentials(user: "anna", password: "pw")
        }
        let login = AdoptOutcome { _ = try fixture.names("/") }
        #expect(asked.wait(timeout: .now() + 120) == .success)
        let session = try fixture.center.session(for: fixture.key)
        fixture.center.noteChosen(fixture.key)
        #expect(try fixture.center.session(for: fixture.key) === session)
        answer.signal()
        #expect(login.ended(within: 120) && !login.failed)
    }
}

/// The order of the Keychain calls when a password is stored (N100), with the Security
/// framework's four calls replaced by a recording stand-in: no Keychain is touched.
@Suite struct Review2NetworkP2Keychain {
    /// A Keychain that holds its items in memory and writes down what it was asked.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        private(set) var log: [String] = []
        var addStatus: OSStatus = errSecSuccess
        var updateStatus: OSStatus?

        private func account(_ query: CFDictionary) -> String {
            ((query as NSDictionary)[kSecAttrAccount] as? String) ?? "?"
        }

        var calls: KeychainPasswords.Calls {
            var calls = KeychainPasswords.Calls()
            calls.copy = { [self] query, result in
                lock.lock(); defer { lock.unlock() }
                log.append("copy \(account(query))")
                guard let data = items[account(query)] else { return errSecItemNotFound }
                result?.pointee = data as CFData
                return errSecSuccess
            }
            calls.update = { [self] query, changes in
                lock.lock(); defer { lock.unlock() }
                log.append("update \(account(query))")
                if let updateStatus { return updateStatus }
                guard items[account(query)] != nil else { return errSecItemNotFound }
                items[account(query)] = (changes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            }
            calls.add = { [self] item in
                lock.lock(); defer { lock.unlock() }
                log.append("add \(account(item))")
                guard addStatus == errSecSuccess else { return addStatus }
                guard items[account(item)] == nil else { return errSecDuplicateItem }
                items[account(item)] = (item as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            }
            calls.delete = { [self] query in
                lock.lock(); defer { lock.unlock() }
                log.append("delete \(account(query))")
                return items.removeValue(forKey: account(query)) == nil ? errSecItemNotFound : errSecSuccess
            }
            return calls
        }

        func clearLog() { lock.lock(); log = []; lock.unlock() }
    }

    @Test func aStoredPasswordIsChangedInPlaceAndNeverRemovedFirst() {
        let keychain = FakeKeychain()
        let passwords = KeychainPasswords(service: "test", calls: keychain.calls)
        // Nothing there yet: looked for by the update, then added.
        passwords.setPassword("one", for: "a")
        #expect(keychain.log == ["update a", "add a"])
        #expect(passwords.password(for: "a") == "one")
        // There already: one update, no delete, no add.
        keychain.clearLog()
        passwords.setPassword("two", for: "a")
        #expect(keychain.log == ["update a"])
        #expect(passwords.password(for: "a") == "two")
        // Removed only when that is asked for.
        keychain.clearLog()
        passwords.setPassword(nil, for: "a")
        #expect(keychain.log == ["delete a"])
        #expect(passwords.password(for: "a") == nil)
    }

    @Test func aChangeThatFailsLeavesTheOldPasswordThere() {
        let keychain = FakeKeychain()
        let passwords = KeychainPasswords(service: "test", calls: keychain.calls)
        passwords.setPassword("kept", for: "a")
        // The Keychain refuses the change (locked, no permission): the old password stays, and
        // nothing is deleted or added in an attempt to get the new one in.
        keychain.updateStatus = errSecInteractionNotAllowed
        keychain.addStatus = errSecInteractionNotAllowed
        keychain.clearLog()
        passwords.setPassword("new", for: "a")
        #expect(keychain.log == ["update a"])
        keychain.updateStatus = nil
        #expect(passwords.password(for: "a") == "kept")
        // A password for an account that has none, when adding fails: nothing else is touched.
        keychain.clearLog()
        passwords.setPassword("x", for: "b")
        #expect(keychain.log == ["update b", "add b"])
        #expect(passwords.password(for: "b") == nil && passwords.password(for: "a") == "kept")
    }

    @Test func theVaultMovesAPasswordWithoutLosingItOnTheWay() {
        let keychain = FakeKeychain()
        let store = KeychainPasswords(service: "test", calls: keychain.calls)
        let vault = PasswordVault(store: store)
        var connection = SavedConnection()
        (connection.name, connection.host, connection.user) = ("one", "a.example", "anna")
        vault.setConnections([connection])
        vault.setPassword("secret", for: connection)
        var moved = connection
        moved.host = "b.example"
        vault.setConnections([moved])
        vault.carryPassword(from: connection, to: moved, removing: true)
        vault.waitUntilDone()
        #expect(vault.password(for: moved.profile) == "secret")
        // The new item was written before the old one was deleted.
        let (old, new) = (PasswordVault.account(of: connection), PasswordVault.account(of: moved))
        let written = keychain.log.firstIndex(of: "add \(new)")
        let deleted = keychain.log.firstIndex(of: "delete \(old)")
        #expect(written != nil && deleted != nil)
        if let written, let deleted { #expect(written < deleted) }
        // The password is bound to the server and the login: nothing is left under the old host.
        #expect(store.password(for: old) == nil && store.password(for: new) == "secret")
    }
}

/// Mounting and ejecting through the system with the system's calls replaced (N066, N103):
/// a mount that is never answered is taken back on Cancel, and an eject that is never
/// answered is given up after its time.
@Suite struct Review2NetworkP2Mounting {
    private final class Token {}

    @Test func aMountThatIsNeverAnsweredIsTakenBackWhenItIsCancelled() throws {
        let token = Token()
        let cancelled = Record<ObjectIdentifier>()
        let answers = Record<(Int32, [String]) -> Void>()
        var calls = SystemVolumeMounter.Calls()
        calls.mount = { _, answer in
            answers.add(answer)
            return (0, token)
        }
        calls.cancel = { cancelled.add(ObjectIdentifier($0)) }
        let mounter = SystemVolumeMounter(calls: calls, unmountTime: 600)
        let flag = CancellationFlag()
        let outcome = AdoptOutcome { _ = try mounter.mount(URL(string: "smb://anna:secret@dead.invalid/share")!, cancellation: flag) }
        #expect(adoptWait(120) { answers.all.count == 1 })
        #expect(!outcome.ended(within: 0.3), "the mount did not wait for the system")
        flag.cancel()
        #expect(outcome.ended(within: 120) && outcome.failed)
        #expect(cancelled.all == [ObjectIdentifier(token)])
        // The system's answer that comes after all goes nowhere, and harms nothing.
        answers.all.first?(0, ["/Volumes/share"])
    }

    @Test func aMountIsAnsweredAndAFailureNamesNoPassword() throws {
        var calls = SystemVolumeMounter.Calls()
        calls.mount = { _, answer in
            DispatchQueue.global().async { answer(0, ["/Volumes/share"]) }
            return (0, nil)
        }
        let mounter = SystemVolumeMounter(calls: calls, unmountTime: 600)
        #expect(try mounter.mount(URL(string: "smb://host.invalid/share")!).map(\.path) == ["/Volumes/share"])

        calls.mount = { _, answer in
            DispatchQueue.global().async { answer(ECONNREFUSED, []) }
            return (0, nil)
        }
        let refused = SystemVolumeMounter(calls: calls, unmountTime: 600)
        do {
            _ = try refused.mount(URL(string: "smb://anna:secret@host.invalid/share")!)
            Issue.record("the mount did not fail")
        } catch {
            #expect(!error.localizedDescription.contains("secret") && error.localizedDescription.contains("host.invalid"))
        }
        // The system refuses to even start.
        calls.mount = { _, _ in (EINVAL, nil) }
        #expect(throws: VolumeError.self) { _ = try SystemVolumeMounter(calls: calls, unmountTime: 600).mount(URL(string: "smb://host.invalid/s")!) }
    }

    @Test func anEjectThatIsNeverAnsweredIsGivenUpAfterItsTime() throws {
        let answers = Record<(Error?) -> Void>()
        var calls = SystemVolumeMounter.Calls()
        calls.unmount = { _, answer in answers.add(answer) }
        // The time is the mounter's own, shortened here; the real one is a minute.
        let mounter = SystemVolumeMounter(calls: calls, unmountTime: 0.3)
        #expect(SystemVolumeMounter.unmountTime == 60)
        #expect(throws: VolumeError.self) { try mounter.unmount(URL(fileURLWithPath: "/Volumes/gone")) }
        // An answer that comes late harms nothing.
        answers.all.first?(nil)

        // An answer in time: success, or the system's error.
        calls.unmount = { _, answer in DispatchQueue.global().async { answer(nil) } }
        try SystemVolumeMounter(calls: calls, unmountTime: 600).unmount(URL(fileURLWithPath: "/Volumes/x"))
        calls.unmount = { _, answer in DispatchQueue.global().async { answer(POSIXError(.EBUSY)) } }
        #expect(throws: POSIXError.self) { try SystemVolumeMounter(calls: calls, unmountTime: 600).unmount(URL(fileURLWithPath: "/Volumes/x")) }
    }
}

/// A certificate check that takes long holds up neither its own stream nor another's (N057).
/// The check is made slow with a hook where it runs; the server is the local TLS test server.
@Suite(.enabled(if: TLSServer.isAvailable)) struct Review2NetworkP2Certificates {
    @Test func aSlowCheckHoldsUpNeitherItsOwnStreamNorAnother() throws {
        let box = try Sandbox()
        try box.folder("srv")
        let server = try TLSServer(mode: .implicit, box: box)
        defer { server.stop() }

        // The first connection's certificate check is held until the test lets go.
        let (entered, release) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        let slow = TLSSettings(host: "127.0.0.1", trust: CertificateTrust())
        slow.beforeEvaluating = {
            entered.signal()
            release.wait()
        }
        let first = NetStream(host: "127.0.0.1", port: server.port, security: .tls(slow))
        first.start()
        defer { first.close() }
        #expect(entered.wait(timeout: .now() + 120) == .success)

        // Its own stream still serves its waits: a time limit and a flag both end them while
        // the check sits there. (They would not if the check ran on the stream's queue.)
        #expect(throws: NetworkError.self) { try first.waitUntilReady(timeout: 0.3) }
        let flag = CancellationFlag()
        let waiting = AdoptOutcome { try first.waitUntilReady(timeout: 600, cancellation: flag) }
        #expect(!waiting.ended(within: 0.3))
        flag.cancel()
        #expect(waiting.ended(within: 120) && waiting.failed)

        // Other connections are checked meanwhile, several at once: each comes to its verdict
        // (the certificate is self-signed, so each is refused and remembered for the question).
        let others = (0..<3).map { _ in TLSSettings(host: "127.0.0.1", trust: CertificateTrust()) }
        let streams = others.map { NetStream(host: "127.0.0.1", port: server.port, security: .tls($0)) }
        streams.forEach { $0.start() }
        defer { streams.forEach { $0.close() } }
        for (settings, stream) in zip(others, streams) {
            #expect(throws: NetworkError.self) { try stream.waitUntilReady(timeout: 120) }
            #expect(settings.rejected?.subject.contains("localhost") == true)
        }
        #expect(slow.rejected == nil, "the held check came to a verdict")

        // Let go, the first check ends like the others.
        release.signal()
        #expect(adoptWait(120) { slow.rejected != nil })
    }
}

/// The test server itself: what the tests lean on when they run side by side.
@Suite struct Review2NetworkP2TestServer {
    @Test func aStoppedServerTakesNoConnectionAndStoppingIsFinal() throws {
        let box = try Sandbox()
        try box.folder("srv")
        // Servers started and stopped in a row while others run: a stopped server's port
        // refuses, and stopping never touches a socket that is another server's by then.
        let steady = try FTPFixture()
        try steady.box.file("srv/a.txt", "a")
        for _ in 0..<40 {
            let server = try TestFTPServer(root: box.url("srv"))
            let key = ServerKey(scheme: "ftp", host: "127.0.0.1", port: server.port)
            let center = ConnectionCenter(environment: SessionEnvironment())
            center.makeSession = { profile, environment in FTPSession(profile: profile, environment: environment) }
            center.noteChosen(key)
            let fs = RemoteFileSystem(scheme: "ftp", center: center)
            #expect(try fs.list(key.url(path: "/"), showHidden: false).isEmpty)
            server.stop()
            server.stop()
            #expect(server.isStopped)
            center.disconnectAll()
            #expect(throws: (any Error).self) { _ = try fs.list(key.url(path: "/"), showHidden: false) }
            // The server that keeps running is not disturbed by the others coming and going.
            #expect(try steady.names("/") == ["a.txt"])
        }
        #expect(steady.server.connectionsOpened == 1)
    }

    @Test func aTransferTheClientGaveUpIsAnsweredWithoutWaitingForATimeLimit() throws {
        // The client asks for a listing and never opens the data connection, then says something
        // else: the server answers 425 at once and goes on, whatever the machine's load.
        let box = try Sandbox()
        try box.folder("srv")
        let server = try TestFTPServer(root: box.url("srv"))
        defer { server.stop() }
        let stream = NetStream(host: "127.0.0.1", port: server.port)
        stream.start()
        defer { stream.close() }
        try stream.waitUntilReady(timeout: 120)
        func line() throws -> String { String(decoding: try stream.readLine(timeout: 120), as: UTF8.self) }
        func say(_ text: String) throws { try stream.write(Data((text + "\r\n").utf8), timeout: 120) }
        #expect(try line().hasPrefix("220"))
        try say("USER anonymous")
        #expect(try line().hasPrefix("230"))
        try say("PASV")
        #expect(try line().hasPrefix("227"))
        try say("LIST")
        #expect(try line().hasPrefix("150"))
        try say("NOOP")
        #expect(try line().hasPrefix("425"))
        #expect(try line().hasPrefix("200"))
    }
}
