import Foundation

/// Finding out in the background where the links of a listing lead.
extension FTPSession {
    /// `handler` is called, from any thread, when the session finds out after a listing where a
    /// link of it leads: the path of the link, and whether it leads to a folder.
    internal func onLinkResolved(_ handler: @escaping @Sendable (String, Bool) -> Void) {
        observerLock.withLock { linkObserver = handler }
    }

    /// The links a listing had no time to ask about are asked after it was delivered, on a
    /// connection of the pool; the next listing of the folder then knows where they lead.
    ///
    /// One resolver per session works through one list: the links of the newest listing come first,
    /// and what does not fit belongs to folders the user has left.
    internal func resolveLinksLater(_ paths: [String]) {
        condition.lock()
        var seen = Set<String>()
        pendingLinks = Array(
            (paths + pendingLinks).filter { seen.insert($0).inserted }.prefix(Self.backgroundLinks)
        )
        linkDeadline = environment.clock().addingTimeInterval(Self.backgroundLinkTime)
        let start = !isResolving && !isClosed
        if start { isResolving = true }
        condition.unlock()
        if start { Background.run(lane: self) { [weak self] in self?.resolveLinks() } }
    }

    /// The resolver.
    ///
    /// It only ever uses a connection nobody else wants: it takes one that is free now (and opens
    /// none that would need a question to the user), asks about a few links, and gives it back;
    /// while a command waits for a connection it stands aside.
    private func resolveLinks() {
        while true {
            let batch = nextLinks()
            if batch.isEmpty {
                break
            }
            let acquired = try? acquire(transfer: nil, fresh: false, background: true, cancellation: closing)
            guard let connection = acquired?.connection else {
                // Nothing is free right now; the links wait. A session that was closed meanwhile
                // ends the resolver at the top of the loop.
                condition.lock()
                pendingLinks = batch + pendingLinks
                linksPutBack += 1
                condition.wait(until: Date().addingTimeInterval(0.5))
                condition.unlock()
                continue
            }
            resolve(batch, on: connection)
            release(connection, transfer: nil)
        }
    }

    /// The next links to ask about, once no command waits; none when the resolver is done (the
    /// session closed, nothing is left, or the time is up).
    private func nextLinks() -> [String] {
        condition.lock()
        defer { condition.unlock() }
        while commandWaiters > 0, !isClosed, !pendingLinks.isEmpty, environment.clock() < linkDeadline {
            condition.wait(until: Date().addingTimeInterval(0.2))
        }
        guard !isClosed, !pendingLinks.isEmpty, environment.clock() < linkDeadline else {
            pendingLinks = []
            isResolving = false
            return []
        }
        let batch = Array(pendingLinks.prefix(Self.backgroundLinkBatch))
        pendingLinks.removeFirst(batch.count)
        return batch
    }

    /// Asks where the links of a batch lead, standing aside (and putting the rest back) when a command
    /// waits; stops when the connection breaks.
    private func resolve(_ batch: [String], on connection: FTPConnection) {
        for (index, full) in batch.enumerated() where links.target(of: full) == nil {
            condition.lock()
            let yields = commandWaiters > 0 || isClosed
            if yields { pendingLinks = Array(batch[index...]) + pendingLinks }
            condition.unlock()
            if yields { break }
            guard let target = connection.probeLink(full, cancellation: closing) else { break }
            // Told first: whoever hears of the link here finds it resolved in the memory too.
            observerLock.withLock { linkObserver }?(full, target == .directory)
            links.remember(full, target: target)
        }
    }
}
