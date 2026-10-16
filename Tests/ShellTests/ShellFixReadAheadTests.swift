import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// Reading ahead by the clock the test sets: a reading that has gone silent or was given up is
/// not taken over, a pause ends, the list of pauses is kept short, a fresh listing is not read
/// again, and an error after a stop is no failure of the folder.
@MainActor
@Suite(.serialized)
internal struct ShellFixReadAheadTests {
    /// The time the read-ahead sees, set by the test.
    private let time = Shared<TimeInterval>(1_000)
    /// The share the folders are on.
    private let server = MemoryFileSystem()
    private let fileSystems = FileSystemRegistry()

    /// A share with the folders `/far`, `/small` and the unreadable `/l1` … `/l3`.
    internal init() {
        server.isLocal = false
        server.addFile("/far/a.txt")
        server.addFile("/small/a.txt")
        for name in ["/l1", "/l2", "/l3"] {
            server.addDirectory(name)
        }
        server.unreadable = ["/l1", "/l2", "/l3"]
        fileSystems.register(server)
    }

    /// What the cursor rests on: `path` of `server`.
    private func target(_ path: String) -> ReadAhead.Target {
        ReadAhead.Target(location: server.url(path), showHidden: false, order: ListOrder())
    }

    /// A read-ahead into `cache` that tells the time by `time`, leaving at most `mostPauses` folders alone.
    private func readAhead(cache: ListingCache = ListingCache(), mostPauses: Int = ReadAhead.pauseLimit) -> ReadAhead {
        let clock = time
        return ReadAhead(fileSystems: fileSystems, cache: cache, clock: { clock.value }, mostPauses: mostPauses)
    }

    /// The cursor rests on `path`, which cannot be read: once it was tried, it is left alone.
    private func fail(_ path: String, in ahead: ReadAhead) async {
        let asked = server.listRequests(for: path)
        ahead.cursorRests(on: target(path))
        #expect(await PanelWait.until { server.listRequests(for: path) == asked + 1 && ahead.reading == nil })
        ahead.cursorRests(on: nil)
    }

    /// The keys of the folders left alone, by path.
    private func paused(_ ahead: ReadAhead) -> Set<String> {
        Set(ahead.pauses.keys)
    }

    /// The key a pause of `path` has.
    private func key(_ path: String) -> String {
        server.url(path).locationKey
    }

    /// A reading that has delivered nothing for a long while is not taken over but told to stop.
    @Test
    internal func aSilentReadingIsNotTakenOverButStopped() async {
        server.stallsListings = true
        let ahead = readAhead()
        defer {
            server.releaseStalls()
            ahead.shutDown()
        }
        ahead.cursorRests(on: target("/far"))
        #expect(await PanelWait.until { server.stalledListings(of: "/far") == 1 })
        time.value += ReadAhead.stalledAfter + 1
        #expect(ahead.join(server.url("/far"), showHidden: false) == nil)
        #expect(ahead.reading?.cancellation.isCancelled == true && ahead.reading?.cancelledAt == time.value)
    }

    /// A reading that has just found its folder too large to be remembered cannot be taken over.
    @Test
    internal func aReadingGivenUpCannotBeTakenOver() async throws {
        server.stallsListings = true
        let ahead = readAhead()
        defer {
            server.releaseStalls()
            ahead.shutDown()
        }
        ahead.cursorRests(on: target("/far"))
        #expect(await PanelWait.until { server.stalledListings(of: "/far") == 1 })
        // The reading thread reports more entries than the cache keeps, the moment before it stops.
        let reading = try #require(ahead.reading)
        #expect(!reading.progress(10, limit: 1))
        #expect(ahead.join(server.url("/far"), showHidden: false) == nil)
        #expect(!reading.isJoined && reading.waiters == 0)
    }

    /// A folder whose pause is over is read again.
    @Test
    internal func aFolderIsReadAgainOnceItsPauseIsOver() async {
        let ahead = readAhead()
        defer { ahead.shutDown() }
        await fail("/l1", in: ahead)
        #expect(paused(ahead) == [key("/l1")])
        // Not before the pause is over …
        ahead.cursorRests(on: target("/l1"))
        await ShellFixTurns.timer(after: ReadAhead.dwell)
        #expect(server.listRequests(for: "/l1") == 1)
        ahead.cursorRests(on: nil)
        // … but then.
        time.value += ReadAhead.pauseAfterError + 1
        await fail("/l1", in: ahead)
        #expect(
            server.listRequests(for: "/l1") == 2 && ahead.pauses[key("/l1")] == time.value + ReadAhead.pauseAfterError
        )
    }

    /// When the pauses reach their limit, those that are over go first.
    @Test
    internal func pausesThatAreOverGoFirstWhenTheLimitIsReached() async {
        let ahead = readAhead(mostPauses: 2)
        defer { ahead.shutDown() }
        await fail("/l1", in: ahead)
        time.value += ReadAhead.pauseAfterError / 2
        await fail("/l2", in: ahead)
        time.value += ReadAhead.pauseAfterError / 2 + 1
        await fail("/l3", in: ahead)
        #expect(paused(ahead) == [key("/l2"), key("/l3")])
    }

    /// When the pauses reach their limit and none is over, they all go.
    @Test
    internal func allPausesGoWhenTheLimitIsReachedAndNoneIsOver() async {
        let ahead = readAhead(mostPauses: 2)
        defer { ahead.shutDown() }
        await fail("/l1", in: ahead)
        await fail("/l2", in: ahead)
        await fail("/l3", in: ahead)
        #expect(paused(ahead) == [key("/l3")])
    }

    /// A folder the cache has just remembered is not read again.
    @Test
    internal func aFolderJustRememberedIsNotReadAgain() async {
        let cache = ListingCache()
        let ahead = readAhead(cache: cache)
        defer { ahead.shutDown() }
        ahead.cursorRests(on: target("/small"))
        #expect(
            await PanelWait.until {
                cache.age(of: server.url("/small"), showHidden: false) != nil && ahead.reading == nil
            }
        )
        ahead.cursorRests(on: nil)
        ahead.cursorRests(on: target("/small"))
        await ShellFixTurns.timer(after: ReadAhead.dwell)
        #expect(server.listRequests(for: "/small") == 1 && ahead.reading == nil && ahead.pauses.isEmpty)
    }

    /// A reading that fails after it was told to stop: that is no failure of the folder, which is
    /// not left alone for it.
    @Test
    internal func anErrorAfterAStopIsNoFailureOfTheFolder() async {
        let script = ScriptedFileSystem()
        script.inner.addDirectory("/x")
        script.batches = [[]]
        script.holdBefore = 0
        script.failure = CocoaError(.fileReadUnknown)
        fileSystems.register(script)
        let ahead = readAhead()
        defer { ahead.shutDown() }
        let location = script.url("/x")
        ahead.cursorRests(on: ReadAhead.Target(location: location, showHidden: false, order: ListOrder()))
        #expect(await PanelWait.until { script.listingsBegun == 1 })
        // The listing fails; before the main thread hears of it, the cursor moves on.
        script.open()
        let sent = ShellFixTurns.afterWorkHeld(inLane: "ahead", at: location) {
            // Only the turn counts.
        }
        #expect(sent)
        #expect(ahead.reading?.cancellation.isCancelled == false)
        ahead.cursorRests(on: nil)
        #expect(await PanelWait.until { ahead.reading == nil })
        #expect(script.listingsEnded == 1 && ahead.pauses.isEmpty)
    }
}
