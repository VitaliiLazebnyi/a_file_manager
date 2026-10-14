import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// What the kernel gives a file system for the calls it does not offer itself.
@Suite
internal struct ProviderDefaultTests {
    /// A reader that cannot be interrupted.
    private final class PlainReader: FileReader {
        let inner: any FileReader

        init(_ inner: any FileReader) { self.inner = inner }

        func read(upToCount count: Int) throws -> Data? { try inner.read(upToCount: count) }

        func seek(to offset: UInt64) throws { try inner.seek(to: offset) }

        func close() { inner.close() }

        deinit {
            // Nothing to release.
        }
    }

    /// A writer that cannot be interrupted.
    private final class PlainWriter: FileWriter {
        let inner: any FileWriter

        init(_ inner: any FileWriter) { self.inner = inner }

        func write(_ data: Data) throws { try inner.write(data) }

        func close(attributes: FileAttributes) throws { try inner.close(attributes: attributes) }

        deinit {
            // Nothing to release.
        }
    }

    /// A file system that offers only what it must: everything else is the kernel's default.
    private final class PlainFileSystem: MemoryBacked {
        let inner = MemoryFileSystem(scheme: "plain")

        var capabilities: FileSystemCapabilities { [.write] }

        func read(_ url: URL) throws -> any FileReader { PlainReader(try inner.read(url)) }

        func write(_ url: URL) throws -> any FileWriter { PlainWriter(try inner.write(url)) }

        deinit {
            // Nothing to release.
        }
    }

    private let plain = PlainFileSystem()

    /// Listings, lean listings and items come from the plain listing; readers and writers
    /// ignore an interruption; the rest says it is not offered or does nothing.
    @Test
    internal func whatAFileSystemDoesNotOfferBehavesAsBefore() throws {
        plain.inner.addFile("/a/one.txt", "12345")
        plain.inner.addDirectory("/a/sub")
        plain.inner.addFile("/a/.hidden")
        let directory = plain.inner.url("/a")
        let file = plain.inner.url("/a/one.txt")
        let flag = CancellationFlag()
        #expect(plain.capabilities(for: file) == [.write])
        #expect(try plain.list(directory, showHidden: false, cancellation: flag).map(\.name) == ["one.txt", "sub"])
        var streamed: [String] = []
        try plain.list(directory, showHidden: true, cancellation: flag) { batch in
            streamed += batch.map(\.name)
            return true
        }
        #expect(streamed == [".hidden", "one.txt", "sub"])
        #expect(plain.item(at: file, cancellation: flag)?.size == 5)
        try checkTransfersAndTheRest(directory: directory, file: file, flag: flag)
    }

    /// A flag that is set already ends listings, items, reading, writing and sizes before they begin.
    @Test
    internal func aFlagThatIsSetEndsTheDefaultsEarly() throws {
        plain.inner.addFile("/a/one.txt")
        let directory = plain.inner.url("/a")
        let file = plain.inner.url("/a/one.txt")
        let flag = CancellationFlag()
        flag.cancel()
        var batches = 0
        try plain.list(directory, showHidden: true, cancellation: flag) { _ in
            batches += 1
            return true
        }
        #expect(batches == 0)
        #expect(plain.item(at: file, cancellation: flag) == nil)
        #expect(throws: CocoaError.self) { try plain.read(file, cancellation: flag) }
        #expect(throws: CocoaError.self) { try plain.write(plain.inner.url("/a/two.txt"), cancellation: flag) }
        #expect(!plain.inner.exists("/a/two.txt"))
        #expect(plain.totalSize(of: directory, cancellation: flag) == 0)
    }

    /// The registry asks each file system for the capabilities at the location, and knows none
    /// where no file system answers.
    @Test
    internal func capabilitiesAreAskedByLocation() throws {
        let memory = MemoryFileSystem()
        let registry = FileSystemRegistry()
        registry.register(memory)
        registry.register(plain)
        memory.capabilities = [.write, .trash]
        #expect(registry.capabilities(for: memory.url("/x")) == [.write, .trash])
        memory.capabilitiesAt = { url in url.path.hasPrefix("/remote") ? [] : [.write, .append] }
        #expect(registry.capabilities(for: memory.url("/remote/x")).isEmpty)
        #expect(registry.capabilities(for: memory.url("/here")) == [.write, .append])
        #expect(memory.capabilities == [.write, .trash])
        #expect(registry.capabilities(for: plain.inner.url("/x")) == [.write])
        let nowhere = try #require(URL(string: "ftp://nowhere/x"))
        #expect(registry.capabilities(for: nowhere).isEmpty)
    }

    /// Readers and writers can be interrupted to no effect; what is not offered says so, or does nothing.
    private func checkTransfersAndTheRest(directory: URL, file: URL, flag: CancellationFlag) throws {
        let reader = try plain.read(file, cancellation: flag)
        reader.interrupt()
        #expect(try reader.read(upToCount: 10) == Data("12345".utf8))
        reader.close()
        let writer = try plain.write(plain.inner.url("/a/new.txt"), cancellation: flag)
        writer.interrupt()
        try writer.write(Data("new".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(plain.inner.contents("/a/new.txt") == "new")
        #expect(throws: FileSystemError.self) { try plain.append(to: file, at: 2, cancellation: CancellationFlag()) }
        #expect(throws: FileSystemError.self) { try plain.copyMetadata(from: directory, to: file) }
        plain.commit(directory, cancellation: CancellationFlag())
        #expect(plain.quarantine(of: file) == nil)
        plain.setQuarantine(Data("0081;x".utf8), of: file)
    }
}
