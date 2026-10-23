import Foundation
import TestSupport

/// A small FTP server for the tests: it listens on 127.0.0.1 on a port the system picks and
/// serves a folder of the test's sandbox.
///
/// One thread per control connection, plain BSD sockets. It speaks enough of the protocol to be a
/// believable server, and can be made to behave like the awkward ones (no MLSD, DOS listings, no
/// EPSV, a password, dropped connections). Unchecked: what changes is guarded by `lock`; the rest
/// is set in `init`.
internal final class TestFTPServer: @unchecked Sendable {
    /// The listening socket and the thread that accepts on it.
    ///
    /// The thread alone closes the socket, once it has seen `isStopped` and is no longer inside a
    /// call on it: a descriptor that is closed under a thread which is about to call `accept` on it
    /// may by then be the number of another server's socket in this process (the tests run side by
    /// side), and that thread would take the other server's connections. Unchecked: `stopped` is
    /// guarded by `lock`; the rest is set in `init`.
    private final class Acceptor: @unchecked Sendable {
        let listener: Int32
        private let lock = NSLock()
        private var stopped = false
        private let ended = DispatchSemaphore(value: 0)

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        init(listener: Int32) { self.listener = listener }

        /// Returns when the socket is closed and nothing is accepted any more.
        func stop() {
            lock.lock()
            let wasStopped = stopped
            stopped = true
            lock.unlock()
            guard !wasStopped else {
                return
            }
            ended.wait()
        }

        func run(_ take: @escaping @Sendable (Int32) -> Bool) {
            let thread = Thread { [self] in
                while !isStopped {
                    var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                    guard poll(&descriptor, 1, 20) > 0 else { continue }
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { continue }
                    if isStopped || !take(client) { close(client) }
                }
                close(listener)
                ended.signal()
            }
            thread.name = "test.ftp.accept"
            thread.start()
        }

        deinit {
            // Nothing to release: the accepting thread closes the socket.
        }
    }

    /// The folder the server serves as its `/`.
    internal let root: URL
    /// The port on 127.0.0.1 the server listens on.
    internal let port: Int
    private let acceptor: Acceptor
    private let lock = NSLock()
    private var currentOptions: Options
    private var clients: Set<Int32> = []
    private var commandLog: [String] = []
    private var opened = 0
    private var listing = 0
    private var mostListing = 0
    private var stopped = false
    private var peak = 0
    private var busy = 0

    /// How the server behaves; a test may change it while the server runs, and the next command
    /// sees the change.
    internal var options: Options {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentOptions
        }
        set {
            lock.lock()
            currentOptions = newValue
            lock.unlock()
        }
    }

    /// Every command line received, in order.
    internal var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return commandLog
    }
    /// How many control connections were ever opened.
    internal var connectionsOpened: Int {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }
    /// How many control connections are open now.
    internal var openConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }
    /// The most control connections that were open at the same moment.
    internal var mostConnectionsAtOnce: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
    /// True once `stop` was called.
    internal var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
    /// The largest number of listings that ran at the same moment.
    internal var mostListingsAtOnce: Int {
        lock.lock()
        defer { lock.unlock() }
        return mostListing
    }

    /// Starts a server for `root` that behaves as `options` say.
    ///
    /// Throws when no listening socket could be had.
    internal init(root: URL, options: Options) throws {
        self.root = root
        currentOptions = options
        let listener = try Self.listen()
        port = Self.port(of: listener)
        acceptor = Acceptor(listener: listener)
        acceptor.run { [weak self] client in
            guard let self else {
                return false
            }
            lock.lock()
            // Stopped between the accept and here: `stop` has cut the connections it knew.
            if stopped {
                lock.unlock()
                return false
            }
            clients.insert(client)
            peak = max(peak, clients.count)
            opened += 1
            lock.unlock()
            Thread.detachNewThread { TestFTPSession(server: self, socket: client).run() }
            return true
        }
    }

    /// Stops accepting and cuts every connection; returns when the listening socket is closed.
    ///
    /// Calling it again does nothing.
    internal func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else {
            return
        }
        acceptor.stop()
        dropConnections()
    }

    /// Cuts every control connection, like a server that timed its clients out.
    internal func dropConnections() {
        // Under the lock: a session takes its socket out of the list, under the same lock,
        // before it closes it, so no descriptor is shut down here that is somebody else's by now.
        lock.lock()
        for client in clients {
            shutdown(client, SHUT_RDWR)
        }
        lock.unlock()
    }

    /// Adds a command line a session received to `commands`.
    internal func record(_ command: String) {
        lock.lock()
        commandLog.append(command)
        lock.unlock()
    }

    /// Closes the socket of a session that ended.
    ///
    /// It leaves the list first (see `dropConnections`).
    internal func closed(_ client: Int32) {
        lock.lock()
        clients.remove(client)
        lock.unlock()
        close(client)
    }

    /// True while connections are still to be refused with 421.
    internal func refusesGreeting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard busy < currentOptions.busyGreetings else {
            return false
        }
        busy += 1
        return true
    }

    /// Counts a listing that begins, for `mostListingsAtOnce`.
    internal func listingStarted() {
        lock.lock()
        listing += 1
        mostListing = max(mostListing, listing)
        lock.unlock()
    }

    /// Counts a listing that is over.
    internal func listingEnded() {
        lock.lock()
        listing -= 1
        lock.unlock()
    }

    /// Waits for the data connection: until it comes, until the client says something else on
    /// the control connection or hangs up (it gave the transfer up), until the server stops,
    /// `Wait.ceiling` at most.
    ///
    /// No short limit: a client on a machine that is busy with other tests may take seconds to get
    /// to its `connect`. Returns the accepted socket, or nil when none came.
    internal func acceptOne(_ listener: Int32, control: Int32) -> Int32? {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !isStopped, Date() < deadline {
            var descriptors = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: control, events: Int16(POLLIN), revents: 0)
            ]
            guard poll(&descriptors, 2, 50) > 0 else { continue }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let client = accept(listener, nil, nil)
                return client >= 0 ? client : nil
            }
            if descriptors[1].revents != 0 {
                return nil
            }
        }
        return nil
    }

    deinit { stop() }
}
