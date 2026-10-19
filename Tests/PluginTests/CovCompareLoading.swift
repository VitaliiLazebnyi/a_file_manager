import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// Loading two files for comparing them: the limits of size, files reached through a link, reads that are cancelled
/// or fail, the check for identical files that is cancelled, and saving over a file on a file system whose moves
/// fail.
@Suite
internal struct CovCompareLoading {
    private let memory = MemoryFileSystem()
    private let fileSystems = FileSystemRegistry()

    /// A registry with the memory file system and the disk.
    internal init() {
        fileSystems.register(memory)
        fileSystems.register(LocalFileSystem())
    }

    /// Files of the same size from the quick-check size on are checked first: identical ones are not loaded, and
    /// different ones are loaded as long as they are not too large.
    @Test
    internal func filesOfTheSameSizeAreCheckedFirstAndLargeOnesAreNotShown() {
        let limits = CompareLoader.Limits(quickCheckFrom: 4, loadLimit: 8)
        memory.addFile("/same1", "abcdef")
        memory.addFile("/same2", "abcdef")
        memory.addFile("/other", "abcdeX")
        memory.addFile("/large1", "0123456789")
        memory.addFile("/large2", "0123456780")
        let identical = load("/same1", "/same2", limits: limits)
        #expect(identical.isIdentical && identical.content.isNone && identical.message == nil)
        let different = load("/same1", "/other", limits: limits)
        #expect(!different.isIdentical && !different.content.isNone)
        let large = load("/large1", "/large2", limits: limits)
        #expect(large.message?.hasPrefix("The two files are different. They are too large") == true)
        #expect(CompareLoader.Limits.standard.quickCheckFrom == 16 << 20)
        #expect(CompareLoader.Limits.standard.loadLimit == 128 << 20)
    }

    /// A file reached through a link is not remembered as it was: it is saved where the link leads.
    @Test
    internal func aFileReachedThroughALinkIsNotRemembered() throws {
        let box = try Sandbox()
        let target = try box.file("target.txt", "one\n")
        try box.file("other.txt", "two\n")
        try FileManager.default.createSymbolicLink(at: box.url("link.txt"), withDestinationURL: target)
        let result = CompareLoader.load(
            left: box.url("link.txt"),
            right: box.url("other.txt"),
            fileSystems: fileSystems
        )
        #expect(result.leftItem == nil && result.rightItem?.name == "other.txt")
        let reversed = CompareLoader.load(
            left: box.url("other.txt"),
            right: box.url("link.txt"),
            fileSystems: fileSystems
        )
        #expect(reversed.rightItem == nil && reversed.leftItem != nil)
    }

    /// A read that is cancelled halfway is a cancelled comparison, and a read that fails is told.
    @Test
    internal func aCancelledOrFailingReadIsTold() throws {
        let hooked = CoverageArchivesFSHookedMemory()
        let registry = FileSystemRegistry()
        registry.register(hooked)
        let big = Data(repeating: 0x61, count: 3 << 19)
        let (left, right) = (
            try CoverageArchivesFSHookedMemory.put(big, at: "/left", on: hooked.base),
            try CoverageArchivesFSHookedMemory.put(big + Data([0x62]), at: "/right", on: hooked.base)
        )
        let cancellation = CancellationFlag()
        hooked.onNextRead { cancellation.cancel() }
        let cancelled = CompareLoader.load(left: left, right: right, fileSystems: registry, cancellation: cancellation)
        #expect(cancelled.wasCancelled && cancelled.content.isNone && cancelled.message == nil)
        // The quick check before loading is cancelled as well.
        let check = CancellationFlag()
        hooked.onNextRead { check.cancel() }
        let checked = CompareLoader.load(
            left: left,
            right: left,
            fileSystems: registry,
            cancellation: check,
            limits: CompareLoader.Limits(quickCheckFrom: 1, loadLimit: 1 << 30)
        )
        #expect(checked.wasCancelled && !checked.isIdentical)
        let box = try Sandbox()
        let locked = try box.file("locked.txt", "secret")
        try box.file("open.txt", "open")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let failed = CompareLoader.load(left: locked, right: box.url("open.txt"), fileSystems: fileSystems)
        #expect(failed.message != nil && !failed.wasCancelled)
    }

    /// The check for identical files ends with no answer when it is cancelled, read side by side or in stretches.
    @Test
    internal func aCancelledCheckForIdenticalFilesHasNoAnswer() throws {
        let hooked = CoverageArchivesFSHookedMemory()
        let registry = FileSystemRegistry()
        registry.register(hooked)
        let data = Data(repeating: 0x61, count: 64)
        let (first, second) = (
            try CoverageArchivesFSHookedMemory.put(data, at: "/first", on: hooked.base),
            try CoverageArchivesFSHookedMemory.put(data, at: "/second", on: hooked.base)
        )
        for (isLocal, stretch) in [(false, 1_024), (true, 4)] {
            hooked.base.isLocal = isLocal
            let cancellation = CancellationFlag()
            // In the first read of every reader: side by side, the workers that open their readers late may find
            // all the stretches taken, and the hook of a reader that never reads would never run.
            hooked.onEveryRead { cancellation.cancel() }
            let answer = try CompareLoader.identical(
                first,
                second,
                size: 64,
                fileSystems: registry,
                cancellation: cancellation,
                stretch: stretch
            )
            #expect(answer == nil, "local: \(isLocal)")
        }
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            try CompareLoader.identical(first, second, size: 64, fileSystems: registry, cancellation: cancelled) == nil
        )
    }

    /// A read that fails while two files are compared side by side is the failure.
    @Test
    internal func aFailingReadWhileComparingSideBySideIsTold() {
        let disk = CovFileOpsScriptedDisk()
        disk.base.isLocal = false
        let registry = FileSystemRegistry()
        registry.register(disk)
        let (first, second) = (disk.base.addFile("/first", "same"), disk.base.addFile("/second", "same"))
        disk.readsBeforeFailure.value = ["/second": 0]
        #expect(throws: CocoaError.self) {
            try CompareLoader.identical(first, second, size: 4, fileSystems: registry)
        }
    }

    /// Nothing loaded is nothing to show.
    @Test
    internal func nothingLoadedIsNone() {
        #expect(CompareContent.none.isNone)
        #expect(!CompareLoader.text(left: TextDocument(), right: TextDocument(), options: DiffOptions()).isNone)
    }

    /// A file system that cannot replace in one step: the old file is moved aside, the new one put in its place, and
    /// the old one taken away; where a step fails, the old file comes back, or both are kept.
    @Test
    internal func savingWhereAFileCannotBeReplacedInOneStep() throws {
        let moving = CovCompareMovingMemory()
        let registry = FileSystemRegistry()
        registry.register(moving)
        moving.base.addFile("/file.txt", "old")
        let file = moving.base.url("/file.txt")
        // Replacing is refused: aside, into place, the old one goes.
        moving.refuses.value = { _, _, replacing in replacing }
        try CompareLoader.replace(file, with: Data("new".utf8), fileSystems: registry)
        #expect(moving.base.contents("/file.txt") == "new" && moving.base.allPaths == ["/file.txt"])
        // The new one cannot be put in place: the old one comes back, and the new one goes.
        moving.refuses.value = { from, _, replacing in replacing || from.hasSuffix(".afm-save") }
        #expect(throws: CovCompareMovingMemory.Refused.self) {
            try CompareLoader.replace(file, with: Data("newer".utf8), fileSystems: registry)
        }
        #expect(moving.base.contents("/file.txt") == "new" && moving.base.allPaths == ["/file.txt"])
        // Nor can the old one come back: both are kept under their own names.
        moving.refuses.value = { from, _, replacing in
            replacing || from.hasSuffix(".afm-save") || from.hasSuffix(".afm-old")
        }
        #expect(throws: CovCompareMovingMemory.Refused.self) {
            try CompareLoader.replace(file, with: Data("newest".utf8), fileSystems: registry)
        }
        #expect(moving.base.allPaths == ["/.file.txt.afm-old", "/.file.txt.afm-save"])
        #expect(moving.base.contents("/.file.txt.afm-save") == "newest")
    }

    /// The old file cannot be moved aside, or a new file cannot be put in place: nothing is left behind.
    @Test
    internal func savingThatCannotMoveLeavesNothingBehind() throws {
        let moving = CovCompareMovingMemory()
        let registry = FileSystemRegistry()
        registry.register(moving)
        moving.base.addFile("/file.txt", "old")
        moving.refuses.value = { _, _, _ in true }
        #expect(throws: CovCompareMovingMemory.Refused.self) {
            try CompareLoader.replace(moving.base.url("/file.txt"), with: Data("new".utf8), fileSystems: registry)
        }
        #expect(throws: CovCompareMovingMemory.Refused.self) {
            try CompareLoader.replace(moving.base.url("/fresh.txt"), with: Data("new".utf8), fileSystems: registry)
        }
        #expect(moving.base.contents("/file.txt") == "old" && moving.base.allPaths == ["/file.txt"])
    }

    /// A file with bytes that were not valid in its encoding is not saved, and says why.
    @Test
    internal func aFileThatWasNotValidIsNotSaved() {
        let document = TextDocument(data: Data([0xEF, 0xBB, 0xBF, 0x61, 0xFF, 0x0A]))
        #expect(!document.isLossless)
        #expect(throws: CompareLoader.SaveError.self) { try document.encodedData(named: "bad.txt") }
        let message = CompareLoader.SaveError.invalidSequences("bad.txt", .utf8(bom: true)).errorDescription
        #expect(
            message == "bad.txt has bytes that are not valid UTF-8 (BOM). Saving would change them, so it is not saved."
        )
    }

    private func load(_ left: String, _ right: String, limits: CompareLoader.Limits) -> ComparedFiles {
        CompareLoader.load(
            left: memory.url(left),
            right: memory.url(right),
            fileSystems: fileSystems,
            limits: limits
        )
    }
}
