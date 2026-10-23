import Foundation

/// The passwords of encrypted members.
extension OpenArchive {
    /// Drops a password that turned out not to fit a member after all; it is not tried first again.
    internal func forget(_ password: String) {
        locked { passwords.removeAll { known in known == password } }
    }

    /// Remembers that the user declined (or gave three wrong passwords), for the operation under way
    /// and for `passwordRefusalMemory`.
    private func noteRefusal() {
        locked {
            if passwordScopes > 0 { refusedInScope = true }
            if environment.passwordRefusalMemory > 0 {
                refusedUntil = Date(timeIntervalSinceNow: environment.passwordRefusalMemory)
            }
        }
    }

    /// Opens an encrypted member with `make`, which throws `wrongPassword` for a password
    /// that does not fit.
    ///
    /// The passwords that have opened members of this archive are tried first. Then the user is
    /// asked, by one thread at a time: whoever waited for the question to be answered tries the
    /// answer before asking again. A refusal (no answer, or three wrong ones) is remembered for the
    /// operation under way (`withPasswordScope`) and for `passwordRefusalMemory`, so that the
    /// members that follow fail without a question.
    internal func unlocked(_ make: (String) throws -> any ByteStream) throws -> (any ByteStream, String) {
        var tried = Set<String>()
        func tryKnown() throws -> (any ByteStream, String)? {
            for candidate in locked({ passwords }) where tried.insert(candidate).inserted {
                do {
                    return (try make(candidate), candidate)
                } catch ArchiveError.wrongPassword {
                    // The next one is tried.
                }
            }
            return nil
        }
        // Asks the user, three times at most; called under `passwordGate`, one thread at a time.
        func asked() throws -> (any ByteStream, String) {
            for attempt in 0..<3 {
                guard let given = environment.askPassword(name, attempt > 0) else {
                    noteRefusal()
                    throw ArchiveError.passwordNeeded(name)
                }
                do {
                    let stream = try make(given)
                    locked {
                        passwords.removeAll { $0 == given }
                        passwords.insert(given, at: 0)
                        if passwords.count > 8 { passwords.removeLast() }
                        (refusedInScope, refusedUntil) = (false, .distantPast)
                    }
                    return (stream, given)
                } catch ArchiveError.wrongPassword {
                    // Asked again, three times at most.
                }
            }
            noteRefusal()
            throw ArchiveError.wrongPassword(name)
        }
        if let opened = try tryKnown() {
            return opened
        }
        // Asked without the directory's lock: the question is put on the main thread.
        passwordGate.lock()
        defer { passwordGate.unlock() }
        if let opened = try tryKnown() {
            return opened
        }
        if locked({ isRefusedLocked }) { throw ArchiveError.passwordNeeded(name) }
        return try asked()
    }

    /// Sets the password to try first, for callers that already know it; nil forgets them all.
    internal func usePassword(_ text: String?) {
        locked {
            guard let text else {
                passwords = []
                return
            }
            passwords.removeAll { $0 == text }
            passwords.insert(text, at: 0)
        }
    }

    /// One operation of the user (unpack, test): inside it the user is asked for a password
    /// until one fits or they decline, and then no more.
    internal func withPasswordScope<T>(_ body: () throws -> T) rethrows -> T {
        locked { passwordScopes += 1 }
        defer {
            locked {
                passwordScopes -= 1
                if passwordScopes == 0 { refusedInScope = false }
            }
        }
        return try body()
    }
}
