import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Review 2, local file system: the places and the volumes.
@Suite
internal struct Review2LocalPlaces {
    /// The file system under test.
    internal let local = LocalFileSystem()

    // MARK: Places and volumes

    /// The places are answered at once, and a list that was read is announced on the main thread.
    @Test
    internal func thePlacesAreAnsweredAtOnceAndAnnouncedWhenTheyChange() async throws {
        let fresh = LocalFileSystem()
        let start = DispatchTime.now().uptimeNanoseconds
        let first = fresh.places()
        for _ in 0..<1_000 { _ = fresh.places() }
        // No call waits for the first reading (it used to wait a second at a time).
        #expect(DispatchTime.now().uptimeNanoseconds - start < 800_000_000)
        #expect(first.first?.kind == .home)
        let settled = fresh.settledPlaces()
        #expect(settled.contains { $0.url.path == "/" && $0.kind == .internalDisk })
        // The read list was announced on the main thread: it differs from the fixed places.
        // Listened for before the file system exists: it begins to read the moment it is
        // made, and may have told the world before a listener that came after it was there.
        let heard = Locked<[(ObjectIdentifier, Bool)]>([])
        let observer = NotificationCenter.default.addObserver(
            forName: LocalFileSystem.placesDidChange,
            object: nil,
            queue: nil
        ) { note in
            guard let sender = note.object as AnyObject? else {
                return
            }
            heard.withValue { $0.append((ObjectIdentifier(sender), Thread.isMainThread)) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let again = LocalFileSystem()
        let own = ObjectIdentifier(again)
        func announcements() -> [Bool] { heard.withValue { $0.filter { $0.0 == own }.map(\.1) } }
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while announcements().isEmpty, Date() < patience { try await Task.sleep(nanoseconds: 10_000_000) }
        // On the main thread, and at least once: other tests of the run attach and detach disk
        // images meanwhile, and each of those is a change of the places that is announced too
        // (seen once in a full run as two announcements where this expected exactly one).
        let told = announcements()
        #expect(!told.isEmpty && told.allSatisfy(\.self), "\(told)")
        withExtendedLifetime(again) {
            // Kept reading up to here.
        }
    }

    /// Many questions about the volume at once all get the same answer.
    @Test
    internal func askingForVolumesOftenIsQuickAndAgrees() throws {
        let box = try Sandbox()
        let first = try #require(local.volume(of: box.root))
        let done = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if local.volume(of: box.url("not/there/yet.txt"))?.name == first.name { done.withValue { $0 += 1 } }
        }
        #expect(done.withValue { $0 } == 200)
    }
}
