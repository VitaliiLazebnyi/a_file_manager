import AFMKernel
import CoreServices
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// The watcher never has the system close descriptor 0: no path that does not fit, one folder per
/// stream, a reserve of descriptors, and descriptor 0 given back to `/dev/null` should the system
/// close it all the same.
///
/// Every test that lets the real system fail, or changes the descriptors of the process, runs in
/// a process of its own: what it breaks there cannot reach the other tests.
/// What is open on descriptor 0 (device, file number, device it stands for); nil when nothing is.
private func fsevZero() -> [Int]? {
    var status = stat()
    guard fstat(0, &status) == 0 else { return nil }
    return [Int(status.st_dev), Int(status.st_ino), Int(status.st_rdev)]
}

@Suite
internal struct FSEvDescriptorZeroTests {
    /// A folder whose path is too long for the system is left out, and descriptor 0 stays.
    ///
    /// Before, the stream was asked for all the same: the system refused it and closed
    /// descriptor 0 on the way, each time it was tried again.
    @Test
    internal func aFolderWhosePathIsTooLongIsLeftOutAndDescriptorZeroStays() async {
        await #expect(processExitsWith: .success) {
            let box = try? Sandbox()
            guard let box, let folder = try? box.folder("short") else { exit(2) }
            let before = fsevZero()
            let refused = DirectoryWatcher.Census.figures.refused
            let watcher = DirectoryWatcher(queue: DispatchQueue(label: "fsev")) { _ in
                // Nothing is looked at.
            }
            let long = URL(fileURLWithPath: "/" + String(repeating: "a", count: 1_100))
            watcher.watch([long, folder])
            // The folder that fits is watched; the other one is not asked for.
            guard Wait.until(seconds: 120, { watcher.watchedFolders == [folder] }) else { exit(3) }
            watcher.stop()
            exit(fsevZero() == before && DirectoryWatcher.Census.figures.refused == refused ? 0 : 1)
        }
    }

    /// Several folders are watched by a stream each, so that running out of descriptors
    /// part-way cannot close descriptor 0; each one's changes are reported.
    @Test
    internal func severalFoldersAreWatchedByAStreamEach() throws {
        let box = try Sandbox()
        let folders = try ["a", "b", "c"].map { try box.folder($0) }
        let made = Shared<[String]>([])
        let counting = FSEvSystem(
            makeStream: { folder, context, callback in
                made.modify { $0.append(folder) }
                return FSEvSystem.live.makeStream(folder, context, callback)
            },
            spareDescriptors: FSEvSystem.live.spareDescriptors
        )
        let changed = Shared(Set<String>())
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "fsev"), system: counting) { urls in
            changed.modify { $0.formUnion(urls.map(\.lastPathComponent)) }
        }
        defer { watcher.stop() }
        watcher.watch(folders)
        #expect(Wait.until(seconds: 120) { watcher.watchedFolders == Set(folders) })
        #expect(made.value.count == 3)
        #expect(Set(made.value.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["a", "b", "c"])
        var count = 0
        // The streams may begin a moment after they were made: changed until all are heard.
        #expect(
            Wait.until {
                count += 1
                for name in ["a", "b", "c"] { _ = try? box.file("\(name)/\(count).txt") }
                return Wait.until(seconds: 1) { changed.value == ["a", "b", "c"] }
            }
        )
    }

    /// When the system makes the stream of one folder but not of the next, the one made is
    /// ended again and nothing is watched, until the next try.
    @Test
    internal func aStreamMadeBeforeOneThatIsRefusedIsEndedAgain() throws {
        let box = try Sandbox()
        let folders = try ["a", "b"].map { try box.folder($0) }
        let tries = Shared(0)
        // The first stream is made; every one after it is refused.
        let failingSecond = FSEvSystem(
            makeStream: { folder, context, callback in
                tries.modify { $0 += 1 }
                return tries.value == 1 ? FSEvSystem.live.makeStream(folder, context, callback) : nil
            },
            spareDescriptors: { 1_000 }
        )
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "fsev"), system: failingSecond) { _ in
            // Nothing is looked at.
        }
        defer { watcher.stop() }
        watcher.watch(folders)
        #expect(Wait.until(seconds: 60) { tries.value >= 2 })
        #expect(watcher.watchedFolders.isEmpty)
    }

    /// A process with too few descriptors to spare makes no stream, and tries again.
    @Test
    internal func aProcessWithTooFewDescriptorsToSpareMakesNoStreamAndTriesAgain() throws {
        let box = try Sandbox()
        let folder = try box.folder("a")
        let spare = Shared(FSEvDescriptors.reserve)
        let (asked, made) = (Shared(0), Shared(0))
        let scarce = FSEvSystem(
            makeStream: { folder, context, callback in
                made.modify { $0 += 1 }
                return FSEvSystem.live.makeStream(folder, context, callback)
            },
            spareDescriptors: {
                asked.modify { $0 += 1 }
                return spare.value
            }
        )
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "fsev"), system: scarce) { _ in
            // Nothing is looked at.
        }
        defer { watcher.stop() }
        watcher.watch([folder])
        // The reserve alone is left: the folder's stream would eat into it.
        #expect(Wait.until(seconds: 60) { asked.value >= 1 })
        #expect(made.value == 0)
        #expect(watcher.watchedFolders.isEmpty)
        // Once there are enough, the next try makes it.
        spare.value = FSEvDescriptors.reserve + 1_000
        #expect(Wait.until(seconds: 120) { watcher.watchedFolders == [folder] })
        #expect(made.value == 1)
    }

    /// A process that is low on descriptors makes no stream until it has enough again, and
    /// descriptor 0 stays.
    @Test
    internal func aProcessLowOnDescriptorsWatchesOnceItHasEnoughAndDescriptorZeroStays() async {
        await #expect(processExitsWith: .success) {
            let box = try? Sandbox()
            guard let box, let folder = try? box.folder((0..<30).map { "d\($0)" }.joined(separator: "/")) else {
                exit(2)
            }
            let before = fsevZero()
            var limit = rlimit()
            getrlimit(RLIMIT_NOFILE, &limit)
            let roomy = limit.rlim_cur
            // What is open now, and the reserve; not enough for the folder and its 30 parents.
            limit.rlim_cur = rlim_t(FSEvDescriptors.openCount() + FSEvDescriptors.reserve + 10)
            setrlimit(RLIMIT_NOFILE, &limit)
            let refused = DirectoryWatcher.Census.figures.refused
            let watcher = DirectoryWatcher(queue: DispatchQueue(label: "fsev")) { _ in
                // Nothing is looked at.
            }
            watcher.watch([folder])
            guard Wait.until(seconds: 120, { DirectoryWatcher.Census.figures.refused > refused }) else { exit(3) }
            guard watcher.watchedFolders.isEmpty, fsevZero() == before else { exit(4) }
            limit.rlim_cur = roomy
            setrlimit(RLIMIT_NOFILE, &limit)
            guard Wait.until(seconds: 120, { watcher.watchedFolders == [folder] }) else { exit(5) }
            watcher.stop()
            exit(fsevZero() == before ? 0 : 1)
        }
    }

    /// When the system closes descriptor 0 while it fails to make a stream, `/dev/null` is put
    /// back on it: what is opened next does not land there and is not closed by the next failure.
    @Test
    internal func descriptorZeroClosedByAFailureIsGivenBackToDevNull() async {
        await #expect(processExitsWith: .success) {
            let tries = Shared(0)
            // What the system does with a path that does not fit.
            let closingZero = FSEvSystem(
                makeStream: { _, _, _ in
                    close(0)
                    tries.modify { $0 += 1 }
                    return nil
                },
                spareDescriptors: { 1_000 }
            )
            let watcher = DirectoryWatcher(queue: DispatchQueue(label: "fsev"), system: closingZero) { _ in
                // Nothing is looked at.
            }
            watcher.watch([URL(fileURLWithPath: NSTemporaryDirectory())])
            guard Wait.until(seconds: 120, { tries.value >= 1 }) else { exit(3) }
            watcher.stop()
            // Asked on the watcher's queue: the try is over by then.
            _ = watcher.watchedFolders
            var null = stat()
            stat("/dev/null", &null)
            exit(fsevZero()?.last == Int(null.st_rdev) ? 0 : 1)
        }
    }

    /// Descriptor 0 is filled only when it is free.
    @Test
    internal func descriptorZeroIsFilledOnlyWhenItIsFree() async {
        let before = fsevZero()
        #expect(!FSEvDescriptors.fillZero())
        #expect(fsevZero() == before)
        await #expect(processExitsWith: .success) {
            close(0)
            exit(FSEvDescriptors.fillZero() && fsevZero() != nil ? 0 : 1)
        }
    }

    /// A path fits when it takes fewer than `PATH_MAX` bytes as the file system spells it.
    @Test
    internal func aPathFitsWhenItsDecomposedSpellingTakesFewerThanPathMaxBytes() {
        #expect(FSEvDescriptors.fits("/" + String(repeating: "a", count: 1_022)))
        #expect(!FSEvDescriptors.fits("/" + String(repeating: "a", count: 1_023)))
        // "é" takes two bytes as written here, three decomposed: 1 + 3 × 340 = 1021 bytes fit, 1024 do not.
        #expect(FSEvDescriptors.fits("/" + String(repeating: "\u{E9}", count: 340)))
        #expect(!FSEvDescriptors.fits("/" + String(repeating: "\u{E9}", count: 341)))
    }

    /// A stream costs a descriptor for the folder and each parent, and a few of its own.
    @Test
    internal func aStreamCostsADescriptorForEachLevelAndAFewOfItsOwn() {
        #expect(FSEvDescriptors.cost(of: "/") == 4)
        #expect(FSEvDescriptors.cost(of: "/private/tmp") == 6)
        let open = FSEvDescriptors.openCount()
        #expect(open >= 3)
        #expect(FSEvDescriptors.spare() > 0)
    }
}
