import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// The options of the Copy dialog that choose what arrives and how: filter, masks, attributes, links.
@Suite
internal struct TransferOptionsInJobs {
    /// The filter decides which files and folders are copied, and whether the folders it leaves empty are made.
    @Test
    internal func theFilterChoosesWhatIsCopied() {
        let (fileSystems, memory) = makeFileSystems()
        for path in [
            "/a/one.txt", "/a/two.bak", "/a/docs/in.txt", "/a/docs/pic.jpg", "/a/docs/build/out.txt",
            "/a/empty/none.jpg"
        ] {
            memory.addFile(path, "x")
        }
        memory.addDirectory("/b")
        let sources = ["one.txt", "two.bak", "docs", "empty"].map { memory.url("/a/" + $0) }
        let result = Replies()
            .run(.copy, sources, to: TargetSpec(directory: memory.url("/b")), fileSystems: fileSystems) { job in
                job.options.filter = CopyFilter("*.txt | build/")
            }
        #expect(
            memory.allPaths.filter { $0.hasPrefix("/b/") } == ["/b/docs", "/b/docs/in.txt", "/b/empty", "/b/one.txt"]
        )
        // A file the filter left out stays selected; a folder that was entered does not.
        #expect(Set(result.completed.map(\.lastPathComponent)) == ["one.txt", "docs", "empty"])

        memory.removeTree("/b")
        memory.addDirectory("/b")
        Replies()
            .run(.copy, sources, to: TargetSpec(directory: memory.url("/b")), fileSystems: fileSystems) { job in
                job.options.filter = CopyFilter("*.txt | build/ **/")
            }
        #expect(memory.allPaths.filter { $0.hasPrefix("/b/") } == ["/b/docs", "/b/docs/in.txt", "/b/one.txt"])
    }

    /// A filtered move leaves what the filter left out in the source folder.
    @Test
    internal func aFilteredMoveKeepsWhatWasLeftOut() {
        let (fileSystems, memory) = makeFileSystems()
        memory.addFile("/a/docs/in.txt", "t")
        memory.addFile("/a/docs/pic.jpg", "j")
        memory.addDirectory("/b")
        Replies()
            .run(
                .move,
                [memory.url("/a/docs")],
                to: TargetSpec(directory: memory.url("/b")),
                fileSystems: fileSystems
            ) { job in
                job.options.filter = CopyFilter("*.txt")
            }
        #expect(memory.allPaths == ["/a", "/a/docs", "/a/docs/pic.jpg", "/b", "/b/docs", "/b/docs/in.txt"])
    }

    /// A mask in the target renames each copy, also relative to the source folder; two copies given one name meet
    /// as a conflict.
    @Test
    internal func renameMasksInTheTarget() throws {
        let (fileSystems, memory) = makeFileSystems()
        let box = try Sandbox()
        try box.file("A/report.txt", "r")
        try box.file("A/notes.md", "n")
        let sources = [box.url("A/report.txt"), box.url("A/notes.md")]
        let spec = TargetSpec.parse(
            "mem:/backup/*.bak",
            sourceDirectory: box.url("A"),
            operandCount: 2,
            fileSystems: fileSystems
        )
        memory.createDirectory(at: spec.directory)
        Replies().run(.copy, sources, to: spec, fileSystems: fileSystems, configure: nil)
        #expect(memory.allPaths == ["/backup", "/backup/notes.bak", "/backup/report.bak"])
        // Relative to the source folder, with a prefix mask.
        let relative = TargetSpec.parse(
            "../old_**.*",
            sourceDirectory: box.url("A"),
            operandCount: 2,
            fileSystems: fileSystems
        )
        Replies().run(.copy, sources, to: relative, fileSystems: fileSystems, configure: nil)
        #expect(box.read("old_notes.md") == "n" && box.read("old_report.txt") == "r")
        // Two sources that land on one name: the second meets the first as a conflict.
        let replies = Replies(.autoRenameCopied)
        replies.run(
            .copy,
            sources,
            to: TargetSpec(directory: memory.url("/backup"), mask: "same.txt"),
            fileSystems: fileSystems,
            configure: nil
        )
        #expect(
            replies.conflicts == ["same.txt"] && memory.contents("/backup/same.txt") == "n"
                && memory.contents("/backup/same (2).txt") == "r"
        )
    }

    /// Folder dates and rights are kept when asked for, and without kept attributes copies get fresh ones.
    @Test
    internal func attributesAndFolderDates() throws {
        let box = try Sandbox()
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)
        try box.file("A/docs/tool.sh", "#!/bin/sh", modified: stamp)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: box.url("A/docs/tool.sh").path)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp, .posixPermissions: 0o700],
            ofItemAtPath: box.url("A/docs").path
        )
        func date(_ path: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: box.url(path).path))?[.modificationDate] as? Date
        }
        func mode(_ path: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: box.url(path).path))?[.posixPermissions] as? Int
        }
        Replies()
            .run(
                .copy,
                [box.url("A/docs")],
                to: TargetSpec(directory: box.url("B")),
                fileSystems: makeFileSystems().0
            ) { job in
                job.options.preservesFolderDates = true
            }
        #expect(
            date("B/docs") == stamp && mode("B/docs") == 0o700 && date("B/docs/tool.sh") == stamp
                && mode("B/docs/tool.sh") == 0o750
        )

        Replies()
            .run(
                .copy,
                [box.url("A/docs")],
                to: TargetSpec(directory: box.url("C")),
                fileSystems: makeFileSystems().0
            ) { job in
                job.options.preservesAttributes = false
            }
        #expect(mode("C/docs/tool.sh") == 0o644 && (date("C/docs/tool.sh") ?? stamp) > Date(timeIntervalSinceNow: -60))
        #expect(date("C/docs") != stamp)
    }

    /// Links are copied as links by default and as what they point to with Follow Links.
    @Test
    internal func linksAreCopiedAsLinksOrFollowed() throws {
        let box = try Sandbox()
        try box.file("real/inside.txt", "i")
        try box.file("real.txt", "content")
        for folder in ["A", "B", "C"] { try box.folder(folder) }
        try FileManager.default.createSymbolicLink(at: box.url("A/dir-link"), withDestinationURL: box.url("real"))
        try FileManager.default.createSymbolicLink(at: box.url("A/file-link"), withDestinationURL: box.url("real.txt"))
        let sources = [box.url("A/dir-link"), box.url("A/file-link")]
        func isLink(_ path: String) -> Bool {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: box.url(path).path)) != nil
        }
        Replies()
            .run(
                .copy,
                sources,
                to: TargetSpec(directory: box.url("B")),
                fileSystems: makeFileSystems().0,
                configure: nil
            )
        #expect(isLink("B/dir-link") && isLink("B/file-link"))
        let replies = Replies()
        replies.run(.copy, sources, to: TargetSpec(directory: box.url("C")), fileSystems: makeFileSystems().0) { job in
            job.options.links = .followLinks
        }
        #expect(!isLink("C/dir-link") && !isLink("C/file-link"))
        #expect(box.read("C/dir-link/inside.txt") == "i" && box.read("C/file-link") == "content")
        #expect(replies.progress.last?.itemsTotal == 3 && replies.progress.last?.bytesTotal == 8)
    }
}
