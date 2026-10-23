import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// The descript.ion comment files: odd first names, combining marks, names they cannot hold, races, pipes,
/// links and hidden files.
@Suite
internal struct Review2FileopsComments {
    // F077
    /// A first name that starts like a byte order mark stays part of the name, in the Windows code page and in UTF-8.
    @Test
    internal func aFirstNameThatLooksLikeAByteOrderMarkStaysAName() throws {
        // `ÿþ` in the Windows code page is FF FE: the mark of UTF-16.
        var file = DescriptIon(data: Data([0x0A, 0xFF, 0xFE]) + Data("x one\r\nother two\r\n".utf8))
        #expect(file.entries.map(\.name) == ["ÿþx", "other"])
        file.setComment("changed", for: "other")
        let again = try #require(DescriptIon(strict: file.data()))
        #expect(again.entries == file.entries && again.encoding == .ansi)
        #expect(!file.data().starts(with: [0xFF, 0xFE]))
        // The same for a file in UTF-8 without a mark whose first name starts with U+FEFF.
        var utf8 = DescriptIon(data: Data("\r\n\u{FEFF}né one\r\n".utf8))
        #expect(utf8.entries.map(\.name) == ["\u{FEFF}né"])
        utf8.setComment("two", for: "b")
        #expect(DescriptIon(strict: utf8.data())?.entries == utf8.entries)
    }

    // F078
    /// The space between name and comment is found next to combining marks and format characters.
    @Test
    internal func separatorsAreFoundNextToCombiningMarks() {
        // A comment that starts with a combining accent, a name that ends with a format character.
        let file = DescriptIon(data: Data("x \u{0301}comment\r\n\"a b\"\u{0301} c\r\nn\u{0600} text\r\n".utf8))
        #expect(file.entries.count == 3)
        #expect(file.entries[0] == DescriptIon.Entry(name: "x", comment: "\u{0301}comment"))
        #expect(file.entries[1].name == "a b")
        #expect(file.entries[2].name == "n\u{0600}" && file.entries[2].comment == "text")
        #expect(DescriptIon(strict: file.data())?.entries.map(\.name) == ["x", "a b", "n\u{0600}"])
        var written = DescriptIon()
        written.setComment("\u{0301}accent first", for: "plain")
        written.setComment("two\nlines", for: "with space")
        #expect(DescriptIon(strict: written.data())?.entries == written.entries)
    }

    // F068
    /// A name the comment file cannot hold is refused and the file left as it was; taking a comment away always
    /// works.
    @Test
    internal func aNameTheFileCannotHoldIsRefusedInsteadOfBeingReadBackAsAnother() throws {
        #expect(
            DescriptIon.canName("plain.txt") && DescriptIon.canName("with space.txt")
                && DescriptIon.canName("quote\"inside")
        )
        #expect(
            !DescriptIon.canName("line\nbreak") && !DescriptIon.canName("a \"b\" c") && !DescriptIon.canName("\"start")
                && !DescriptIon.canName("")
        )
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        memory.addFile("/A/descript.ion", "keep.txt kept\r\n")
        let store = CommentStore(fileSystems: fileSystems)
        #expect(throws: CommentFileError.self) {
            try store.setComment(
                "x",
                for: "a \"b\" c",
                in: memory.url("/A"),
                hidden: false,
                cancellation: CancellationFlag()
            )
        }
        #expect(memory.contents("/A/descript.ion") == "keep.txt kept\r\n")
        // Taking a comment away is always possible.
        try store.setComment(
            "",
            for: "a \"b\" c",
            in: memory.url("/A"),
            hidden: false,
            cancellation: CancellationFlag()
        )
        try store.setComment(
            "fine",
            for: "quote\"inside",
            in: memory.url("/A"),
            hidden: false,
            cancellation: CancellationFlag()
        )
        #expect(
            store.comments(in: memory.url("/A"), cancellation: CancellationFlag()) == [
                "keep.txt": "kept", "quote\"inside": "fine"
            ]
        )
    }

    // F036, F065
    /// Comments read before a change was written are not remembered as the folder's comments.
    @Test
    internal func aReadingThatBeganBeforeAChangeIsNotRemembered() throws {
        let gated = GatedFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(gated)
        gated.base.addFile("/A/descript.ion", "a.txt old\r\n")
        let store = CommentStore(fileSystems: fileSystems)
        let folder = gated.base.url("/A")
        gated.holdNextRead()
        let first = DispatchSemaphore(value: 0)
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var stale: [String: String] = [:]
        Thread.detachNewThread {
            stale = store.comments(in: folder, cancellation: CancellationFlag())
            first.signal()
        }
        // The reader has the old file in hand; now the comment changes.
        gated.entered.wait()
        try store.setComment("new", for: "a.txt", in: folder, hidden: false, cancellation: CancellationFlag())
        gated.gate.signal()
        first.wait()
        #expect(stale == ["a.txt": "old"])
        // What was read before the change was not kept: the next question reads the file again.
        #expect(store.comments(in: folder, cancellation: CancellationFlag()) == ["a.txt": "new"])
    }

    // F066
    /// A pipe called descript.ion is neither read nor written.
    @Test
    internal func aPipeCalledLikeTheCommentFileIsNotRead() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let pipe = box.url("d/descript.ion")
        try box.folder("d")
        #expect(mkfifo(pipe.path, 0o644) == 0)
        let store = CommentStore(fileSystems: fileSystems)
        let done = DispatchSemaphore(value: 0)
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var refused = false
        Thread.detachNewThread {
            _ = store.comments(in: box.url("d"), cancellation: CancellationFlag())
            refused =
                (try? store.setComment(
                    "x",
                    for: "a.txt",
                    in: box.url("d"),
                    hidden: false,
                    cancellation: CancellationFlag()
                )) == nil
            done.signal()
        }
        let ended = done.wait(timeout: .now() + 60) == .success
        if !ended {
            // Let the reader that hangs go, so the test ends.
            let descriptor = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { close(descriptor) }
            _ = done.wait(timeout: .now() + 10)
        }
        #expect(ended && refused)
    }

    // F067
    /// A comment file that is a link, or hidden by another program, stays a link or hidden when a comment changes.
    @Test
    internal func aLinkedOrHiddenCommentFileStaysLinkedAndHidden() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let store = CommentStore(fileSystems: fileSystems)
        let real = try box.file("shared/descript.ion", "a.txt old\r\n")
        try box.folder("d")
        try FileManager.default.createSymbolicLink(at: box.url("d/descript.ion"), withDestinationURL: real)
        try store.setComment("new", for: "a.txt", in: box.url("d"), hidden: false, cancellation: CancellationFlag())
        #expect(LocalInfo.isSymlink(box.url("d/descript.ion")) && box.read("shared/descript.ion") == "a.txt new\r\n")
        // Hidden by another program, with hiding switched off here: it stays hidden.
        let hidden = try box.file("h/descript.ion", "a.txt old\r\n")
        try LocalInfo.setFlag(UInt32(UF_HIDDEN), true, of: hidden)
        try store.setComment("new", for: "a.txt", in: box.url("h"), hidden: false, cancellation: CancellationFlag())
        #expect(LocalInfo.details(hidden)?.isHidden == true && box.read("h/descript.ion") == "a.txt new\r\n")
    }
}
