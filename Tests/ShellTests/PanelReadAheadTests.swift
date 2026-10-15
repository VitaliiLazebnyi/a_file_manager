import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// Reading the folder under the cursor ahead, by itself: what it leaves alone, and how a panel
/// takes a reading over and leaves it again.
@MainActor
@Suite(.serialized)
internal struct PanelReadAheadTests {
    /// What the cursor rests on: `path` of `server`, as the panel reads it.
    private func target(_ path: String, on server: MemoryFileSystem) -> ReadAhead.Target {
        ReadAhead.Target(location: server.url(path), showHidden: false, order: ListOrder())
    }

    /// A folder larger than the cache keeps is given up and not read again for a long while; one
    /// that fits is read once and remembered.
    @Test
    internal func aFolderTheCacheCannotKeepIsNotReadAheadAgainAndAgain() async {
        var limits = ListingCache.Limits()
        limits.maxEntries = 30
        let cache = ListingCache(limits: limits)
        let server = MemoryFileSystem()
        server.isLocal = false
        for index in 0..<50 {
            server.addFile("/big/f\(index).txt")
        }
        server.addFile("/small/a.txt")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(server)
        let ahead = ReadAhead(fileSystems: fileSystems, cache: cache)
        defer { ahead.shutDown() }
        ahead.cursorRests(on: target("/big", on: server))
        ahead.cursorRests(on: target("/big", on: server))
        #expect(
            await PanelWait.until {
                server.listRequests(for: "/big") == 1 && ahead.reading == nil && ahead.pauses.count == 1
            }
        )
        #expect(cache.age(of: server.url("/big"), showHidden: false) == nil)
        // The cursor stays where it is for several rests' time: the folder is left alone.
        await PanelWait.pause(ReadAhead.dwell * 4)
        #expect(server.listRequests(for: "/big") == 1)
        // Going away and coming back does not read it either, for a long while.
        ahead.cursorRests(on: nil)
        ahead.cursorRests(on: target("/big", on: server))
        await PanelWait.pause(ReadAhead.dwell * 3)
        #expect(server.listRequests(for: "/big") == 1)
        // A folder that fits is read once and remembered; once there, it is not read again.
        ahead.cursorRests(on: target("/small", on: server))
        #expect(
            await PanelWait.until {
                cache.age(of: server.url("/small"), showHidden: false) != nil && ahead.reading == nil
            }
        )
        ahead.cursorRests(on: nil)
        ahead.cursorRests(on: target("/small", on: server))
        await PanelWait.pause(ReadAhead.dwell * 2)
        #expect(server.listRequests(for: "/small") == 1 && ahead.pauses.count == 1)
    }

    /// A reading that panels took over goes on while one of them waits; when the last leaves,
    /// it is stopped, which is no failure of the folder.
    @Test
    internal func aReadAheadThatIsTakenOverIsStoppedWhenNobodyWaitsForItAnyMore() async {
        let server = MemoryFileSystem()
        server.isLocal = false
        server.stallsListings = true
        server.addFile("/far/a.txt")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(server)
        let ahead = ReadAhead(fileSystems: fileSystems, cache: ListingCache())
        defer {
            server.releaseStalls()
            ahead.shutDown()
        }
        ahead.cursorRests(on: target("/far", on: server))
        #expect(await PanelWait.until { ahead.reading != nil && server.listRequests(for: "/far") == 1 })
        // Only exactly this folder, read the same way, is taken over.
        #expect(
            ahead.join(server.url("/other"), showHidden: false) == nil
                && ahead.join(server.url("/far"), showHidden: true) == nil
        )
        // Two panels take the reading over and the cursor moves on: the reading goes on for them.
        let (first, second) = (
            ahead.join(server.url("/far"), showHidden: false), ahead.join(server.url("/far"), showHidden: false)
        )
        var outcomes = 0
        first?.receive { _ in outcomes += 1 }
        second?.receive { _ in outcomes += 1 }
        ahead.cursorRests(on: nil)
        #expect(first != nil && second != nil && ahead.reading != nil)
        // One of them moves on (twice, which counts once): the other still waits.
        first?.leave()
        first?.leave()
        await PanelWait.pause(0.2)
        #expect(ahead.reading != nil)
        // The other leaves as well: nobody wants the reading, and it is told to stop.
        second?.leave()
        #expect(await PanelWait.until { ahead.reading == nil })
        #expect(outcomes == 0 && ahead.pauses.isEmpty)
    }

    /// A folder that could not be read is left alone.
    ///
    /// A reading that does not come back after it was told to stop (here its lane is held up by a
    /// call that does not return) holds up the next folder, until it was told so long ago that it
    /// is left behind; nothing is taken over once it was told to stop.
    @Test
    internal func aStuckReadingIsLeftBehind() async {
        let server = MemoryFileSystem()
        server.addDirectory("/locked")
        server.unreadable = ["/locked"]
        server.addFile("/stuck/a.txt")
        server.addFile("/next/a.txt")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(server)
        let ahead = ReadAhead(fileSystems: fileSystems, cache: ListingCache())
        let gate = DispatchSemaphore(value: 0)
        Background.storage("ahead", at: server.url("/stuck")) { gate.wait() }
        defer {
            gate.signal()
            ahead.shutDown()
        }
        ahead.cursorRests(on: target("/locked", on: server))
        #expect(await PanelWait.until { server.listRequests(for: "/locked") == 1 && ahead.reading == nil })
        #expect(ahead.pauses.count == 1)
        ahead.cursorRests(on: target("/stuck", on: server))
        #expect(await PanelWait.until { ahead.reading != nil })
        ahead.cursorRests(on: target("/next", on: server))
        #expect(
            ahead.reading?.cancellation.isCancelled == true
                && ahead.join(server.url("/stuck"), showHidden: false) == nil
        )
        await PanelWait.pause(ReadAhead.dwell * 2)
        #expect(server.listRequests(for: "/next") == 0 && ahead.reading != nil)
        // Told to stop long ago, as far as the read-ahead knows: the next folder gets its turn.
        ahead.reading?.cancelledAt = ProcessInfo.processInfo.systemUptime - ReadAhead.abandonAfter - 1
        ahead.cursorRests(on: nil)
        ahead.cursorRests(on: target("/next", on: server))
        #expect(await PanelWait.until { server.listRequests(for: "/next") == 1 })
        #expect(server.listRequests(for: "/stuck") == 0)
    }

    /// A reading taken over before its thread began goes at the user's priority from the start;
    /// one given up as too large cannot be taken over.
    @Test
    internal func aReadingIsRaisedWhenJoinedAndCannotBeJoinedOnceGivenUp() {
        let target = ReadAhead.Target(location: URL(fileURLWithPath: "/x"), showHidden: false, order: ListOrder())
        let joined = ReadAheadReading(target: target)
        #expect(joined.join() && joined.isJoined)
        joined.began()
        #expect(joined.progress(10, limit: 5))
        joined.finished()
        let large = ReadAheadReading(target: target)
        #expect(!large.progress(10, limit: 5) && large.wasGivenUp && !large.join())
    }

    /// A reading a panel took over and left again while the cursor rests nowhere is stopped.
    @Test
    internal func aReadingLeftWhileTheCursorRestsNowhereIsStopped() async throws {
        let server = MemoryFileSystem()
        server.isLocal = false
        server.listStartDelay = 1
        server.addFile("/slow/a.txt")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(server)
        let ahead = ReadAhead(fileSystems: fileSystems, cache: ListingCache())
        defer { ahead.shutDown() }
        ahead.cursorRests(on: target("/slow", on: server))
        #expect(await PanelWait.until { ahead.reading != nil })
        // Left while the cursor still rests on the folder: the reading goes on.
        try #require(ahead.join(server.url("/slow"), showHidden: false)).leave()
        #expect(ahead.reading?.cancellation.isCancelled == false)
        let joined = try #require(ahead.join(server.url("/slow"), showHidden: false))
        ahead.cursorRests(on: nil)
        #expect(ahead.reading?.cancellation.isCancelled == false)
        joined.leave()
        #expect(ahead.reading?.cancellation.isCancelled != false)
    }

    /// A folder of a local disk that was read but that the cache did not keep is left alone for a
    /// while: reading it again would end the same way.
    @Test
    internal func aFolderTheCacheDidNotKeepIsLeftAlone() async {
        let server = MemoryFileSystem()
        server.isLocal = true
        server.addFile("/local/a.txt")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(server)
        let ahead = ReadAhead(fileSystems: fileSystems, cache: ListingCache())
        defer { ahead.shutDown() }
        ahead.cursorRests(on: target("/local", on: server))
        #expect(await PanelWait.until { server.listRequests(for: "/local") == 1 && ahead.reading == nil })
        #expect(ahead.pauses.count == 1)
    }
}
