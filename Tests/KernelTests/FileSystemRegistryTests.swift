import AFMKernel
import Foundation
import TestSupport
import Testing

/// The file-system registry: which file system answers for a location, and locations typed by the user.
@Suite
internal struct FileSystemRegistryTests {
    /// A location of a scheme nobody registered has no provider and no entry.
    @Test
    internal func unknownSchemesHaveNoProvider() {
        let fileSystems = FileSystemRegistry()
        #expect(throws: FileSystemError.self) { try fileSystems.provider(for: URL(fileURLWithPath: "/tmp")) }
        #expect(fileSystems.item(at: URL(fileURLWithPath: "/tmp")) == nil)
    }

    /// Relative paths, `..`, absolute paths, the empty text and full URLs are read against the
    /// folder they were typed in; local paths and `~` are read as on the disk.
    @Test
    internal func readsTypedLocations() {
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        let base = memory.url("/work/docs")
        #expect(
            fileSystems.location(from: "sub/a.txt", relativeTo: base)
                .isSameLocation(as: memory.url("/work/docs/sub/a.txt"))
        )
        #expect(fileSystems.location(from: "..", relativeTo: base).isSameLocation(as: memory.url("/work")))
        #expect(fileSystems.location(from: "/top", relativeTo: base).isSameLocation(as: memory.url("/top")))
        #expect(fileSystems.location(from: "", relativeTo: base).isSameLocation(as: base))
        #expect(
            fileSystems.location(from: "mem:///other/place", relativeTo: URL(fileURLWithPath: "/tmp"))
                .isSameLocation(as: memory.url("/other/place"))
        )
        let local = URL(fileURLWithPath: "/tmp")
        #expect(fileSystems.location(from: "/usr/bin", relativeTo: local).path == "/usr/bin")
        #expect(fileSystems.location(from: "~/x", relativeTo: local).path == NSHomeDirectory() + "/x")
    }

    /// Each file system writes its own locations for the user, and reads back what it wrote.
    @Test
    internal func displayPathsAreReadBack() throws {
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        let base = memory.url("/work/docs")
        let local = URL(fileURLWithPath: "/tmp")
        #expect(fileSystems.displayPath(base) == "mem:/work/docs")
        #expect(fileSystems.displayPath(try #require(URL(string: "ftp://host/x"))) == "ftp://host/x")
        // Dialogs propose targets this way.
        #expect(
            fileSystems.location(from: fileSystems.displayPath(base) + "/new.txt", relativeTo: local)
                .isSameLocation(as: memory.url("/work/docs/new.txt"))
        )
        #expect(fileSystems.location(from: "mem:/top/*.*", relativeTo: local).path == "/top/*.*")
    }
}
