import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// What a job does with pipes, and with sources that come to the same name in the target.
@Suite
internal struct Review2FileopsJob {
    /// A scratch folder of its own for each test.
    internal let box: Sandbox

    /// A fresh scratch folder.
    internal init() throws {
        box = try Sandbox()
    }

    /// Runs `work` on another thread and waits for it; if it does not end in `seconds`, `rescue`
    /// is called (to free whatever it hangs on) and false comes back.
    ///
    /// The time only matters when the code under test hangs, which is the failure the test is there to
    /// catch.
    private static func finishes(
        within seconds: TimeInterval = 60,
        rescue: () -> Void,
        work: @escaping @Sendable () -> Void
    ) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            work()
            done.signal()
        }
        if done.wait(timeout: .now() + seconds) == .success {
            return true
        }
        rescue()
        _ = done.wait(timeout: .now() + 10)
        return false
    }

    // MARK: F007, F017

    /// A pipe and a link to one, in a folder copied to another file system, are reported and never opened.
    @Test
    internal func aPipeInAStreamedCopyIsReportedAndNeverOpened() throws {
        let (fileSystems, memory) = makeFileSystems()
        try box.file("s/real.txt", "data")
        let pipe = box.url("s/pipe")
        #expect(mkfifo(pipe.path, 0o644) == 0)
        try FileManager.default.createSymbolicLink(at: box.url("s/toPipe"), withDestinationURL: pipe)
        memory.addDirectory("/t")
        let replies = Review2Replies()
        let ended = Self.finishes(
            rescue: {
                // Opening the other end lets a reader that hangs go on.
                let descriptor = open(pipe.path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 { close(descriptor) }
            },
            work: {
                let job = FileJob(
                    kind: .copy,
                    sources: [box.url("s")],
                    target: TargetSpec(directory: memory.url("/t")),
                    fileSystems: fileSystems
                )
                job.delegate = replies
                _ = job.run()
            }
        )
        #expect(ended, "the copy of a folder with a pipe did not end")
        #expect(
            memory.contents("/t/s/real.txt") == "data" && !memory.exists("/t/s/pipe") && !memory.exists("/t/s/toPipe")
        )
        #expect(replies.errors.count == 2 && replies.errors.allSatisfy { $0.contains("pipe") })
    }

    /// Neither a checksum nor a copy that follows links reads a pipe; a link to a pipe copied as a link is a link.
    @Test
    internal func aPipeIsNotReadForAChecksumOrACopyThatFollowsLinks() throws {
        let (fileSystems, _) = makeFileSystems()
        let pipe = box.url("pipe")
        #expect(mkfifo(pipe.path, 0o644) == 0)
        try box.folder("s")
        try FileManager.default.createSymbolicLink(at: box.url("s/link"), withDestinationURL: pipe)
        #expect(throws: FileJobError.self) { _ = try Checksum.sha256(of: pipe, in: fileSystems) }
        #expect(throws: FileJobError.self) { _ = try Checksum.sha256(of: box.url("s/link"), in: fileSystems) }
        try box.folder("t")
        let replies = Review2Replies()
        let ended = Self.finishes(
            rescue: {
                let descriptor = open(pipe.path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 { close(descriptor) }
            },
            work: {
                let job = FileJob(
                    kind: .copy,
                    sources: [box.url("s/link")],
                    target: TargetSpec(directory: box.url("t")),
                    fileSystems: fileSystems
                )
                job.options.links = .followLinks
                job.delegate = replies
                _ = job.run()
            }
        )
        #expect(ended && replies.errors.count == 1 && namesOnDisk(box.url("t")).isEmpty)
        // Where links are copied as links, a link to a pipe is just a link.
        Answers().run(.copy, [box.url("s/link")], to: TargetSpec(directory: box.url("t")), fileSystems: fileSystems)
        #expect(FileIdentity.isSymlink(box.url("t/link")))
    }

    // MARK: F006, F013

    /// Two sources of one name from two folders both arrive under Overwrite All, the second under a numbered name.
    @Test
    internal func equallyNamedSourcesFromTwoFoldersBothArriveUnderOverwriteAll() throws {
        let (fileSystems, _) = makeFileSystems()
        let sources = [try box.file("s/a/x.txt", "from-a"), try box.file("s/b/x.txt", "from-b")]
        try box.folder("t")
        let answers = Answers()
        let job = FileJob(
            kind: .move,
            sources: sources,
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.options.overwrite = .overwriteAll
        job.delegate = answers
        let result = job.run()
        #expect(result.completed.count == 2 && answers.conflicts.isEmpty && answers.errors.isEmpty)
        #expect(namesOnDisk(box.url("t")) == ["x (2).txt", "x.txt"])
        #expect(Set([box.read("t/x.txt"), box.read("t/x (2).txt")]) == ["from-a", "from-b"])
        #expect(!box.exists("s/a/x.txt") && !box.exists("s/b/x.txt"))
    }

    /// A mask that gives several sources one name loses none of them, whatever overwrite rule is set.
    @Test
    internal func aMaskThatGivesSeveralSourcesOneNameLosesNone() throws {
        let (fileSystems, _) = makeFileSystems()
        let sources = [
            try box.file("s/a.doc", "doc"), try box.file("s/a.pdf", "pdf"), try box.file("s/a.rtf", "rtf")
        ]
        try box.folder("t")
        for mode in [OverwriteMode.overwriteAll, .overwriteOlder, .overwriteOlderOrSame, .copyLarger] {
            let target = box.url("t/\(mode.rawValue)")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let job = FileJob(
                kind: .copy,
                sources: sources,
                target: TargetSpec(directory: target, mask: "*.txt"),
                fileSystems: fileSystems
            )
            job.options.overwrite = mode
            let answers = Answers()
            job.delegate = answers
            _ = job.run()
            #expect(namesOnDisk(target) == ["a (2).txt", "a (3).txt", "a.txt"], "mode \(mode)")
            let contents = namesOnDisk(target)
                .map { name in try? String(contentsOf: target.appendingPathComponent(name), encoding: .utf8) }
            #expect(Set(contents) == ["doc", "pdf", "rtf"])
        }
    }

    /// Overwrite All never replaces a file the job itself wrote; Overwrite for that one file does.
    @Test
    internal func anAnswerForAllDoesNotOverwriteTheJobsOwnFileButAnAnswerForOneDoes() throws {
        let (fileSystems, _) = makeFileSystems()
        let sources = [try box.file("s/a/x.txt", "from-a"), try box.file("s/b/x.txt", "from-b")]
        try box.folder("t")
        try box.folder("u")
        // In "ask" mode the question comes; "Overwrite all" is a rule, and no rule destroys the job's own file.
        let all = Answers()
        all.conflict = .overwriteAll
        all.run(.copy, sources, to: TargetSpec(directory: box.url("t")), fileSystems: fileSystems)
        #expect(all.conflicts == ["x.txt"] && namesOnDisk(box.url("t")) == ["x (2).txt", "x.txt"])
        // "Overwrite" for this one file is what the user said about exactly this file.
        let one = Answers()
        one.conflict = .overwrite
        one.run(.copy, sources, to: TargetSpec(directory: box.url("u")), fileSystems: fileSystems)
        #expect(one.conflicts == ["x.txt"] && namesOnDisk(box.url("u")) == ["x.txt"])
    }

    /// Two source folders that merge into one target folder keep each other's files.
    @Test
    internal func twoSourceFoldersThatLandInOneTargetFolderKeepEachOthersFiles() throws {
        let (fileSystems, _) = makeFileSystems()
        try box.file("s/one/sub/x.txt", "first")
        try box.file("s/one/sub/only1.txt", "1")
        try box.file("s/two/sub/x.txt", "second")
        try box.file("t/sub/old.txt", "old")
        let job = FileJob(
            kind: .move,
            sources: [box.url("s/one/sub"), box.url("s/two/sub")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.options.overwrite = .overwriteAll
        let answers = Answers()
        job.delegate = answers
        _ = job.run()
        #expect(namesOnDisk(box.url("t/sub")) == ["old.txt", "only1.txt", "x (2).txt", "x.txt"])
        #expect(Set([box.read("t/sub/x.txt"), box.read("t/sub/x (2).txt")]) == ["first", "second"])
    }

    /// A file that was in the target before the job is still replaced by Overwrite All.
    @Test
    internal func aFileThatWasThereBeforeTheJobIsStillOverwrittenByTheRule() throws {
        let (fileSystems, _) = makeFileSystems()
        try box.file("s/x.txt", "new")
        try box.file("t/x.txt", "old")
        let job = FileJob(
            kind: .copy,
            sources: [box.url("s/x.txt")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.options.overwrite = .overwriteAll
        _ = job.run()
        #expect(namesOnDisk(box.url("t")) == ["x.txt"] && box.read("t/x.txt") == "new")
    }
}
