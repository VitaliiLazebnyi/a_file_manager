import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// The pure parts: reading a typed line, running a child process, formats and pages.
@Suite
internal struct SystemToolsTypes {
    // MARK: File lists

    /// The moment the file lists of the tests are made at.
    internal let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Typed lines

    /// A leading `~` or `~user` is read as that user's home folder, as a shell reads it; a user
    /// nobody knows leaves the path as it is.
    @Test
    internal func aTildeIsAHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(TypedCommand.expandingTilde(in: "~") == home)
        #expect(TypedCommand.expandingTilde(in: "~/Apps/X.app") == home + "/Apps/X.app")
        #expect(TypedCommand.expandingTilde(in: "~\(NSUserName())/x") == home + "/x")
        #expect(TypedCommand.expandingTilde(in: "~afm-nobody-of-this-name/x") == "~afm-nobody-of-this-name/x")
        #expect(TypedCommand.expandingTilde(in: "/a/~b") == "/a/~b")
        #expect(TypedCommand.location(of: "~/x", relativeTo: URL(fileURLWithPath: "/tmp")).path == home + "/x")
    }

    /// A typed line is taken apart into its program, its arguments and whether it is detached.
    @Test
    internal func aLineIsTakenApart() throws {
        let plain = try #require(TypedCommand("  ls -la  "))
        #expect(plain.command == "ls -la" && plain.firstWord == "ls" && plain.arguments == "-la" && !plain.isDetached)
        let detached = try #require(TypedCommand("open . &"))
        #expect(detached.command == "open ." && detached.isDetached)
        #expect(TypedCommand("make && make install &&")?.isDetached == false)
        #expect(TypedCommand("") == nil && TypedCommand("  &") == nil)
        #expect(TypedCommand("\"My Tool.app\" file.txt")?.firstWord == "My Tool.app")
        #expect(TypedCommand("My\\ Tool --flag")?.firstWord == "My Tool")
        #expect(TypedCommand("'it''s' x")?.firstWord == "its")
        #expect(TypedCommand.split("a   'b c'  d").rest == "'b c'  d")
    }

    /// Applications are found by name in the given folders or by path; a name with arguments is not one.
    @Test
    internal func applicationsAreFoundByNameOrPath() throws {
        let box = try Sandbox()
        try box.folder("Apps/Tool.app")
        try box.file("Apps/script.app", "not a bundle")
        let folders = [box.url("Apps")]
        func found(_ line: String, in searched: [URL]) -> URL? {
            TypedCommand(line)?.application(relativeTo: box.root, searching: searched, path: TypedCommand.processPath)
        }
        #expect(found("Tool", in: folders)?.lastPathComponent == "Tool.app")
        #expect(found("Tool.app notes.txt", in: folders)?.lastPathComponent == "Tool.app")
        #expect(found("Apps/Tool.app", in: [])?.path == box.url("Apps/Tool.app").path)
        // A name with arguments is a program for the shell, and a file is not an application.
        #expect(found("Tool --help", in: folders) == nil)
        #expect(found("script", in: folders) == nil)
        #expect(found("ls", in: folders) == nil)
        #expect(
            SystemTools.files(in: "a.txt 'b c.txt' /tmp/d", relativeTo: box.root).map(\.path)
                == [box.url("a.txt").path, box.url("b c.txt").path, "/tmp/d"]
        )
    }

    /// Only plain lines of harmless programs are harmless.
    @Test
    internal func onlyPlainHarmlessLinesAreHarmless() throws {
        #expect(SystemTools.isHarmless(try #require(TypedCommand("echo a b"))))
        #expect(!SystemTools.isHarmless(try #require(TypedCommand("echo a | sh"))))
        #expect(!SystemTools.isHarmless(try #require(TypedCommand("sh -c 'echo a'"))))
    }

    /// The history keeps each line once, newest first, up to its limit.
    @Test
    internal func theHistoryKeepsEachLineOnceNewestFirst() {
        var history: [String] = []
        for line in ["a", "b", "a"] { history = CommandHistory.adding(line, to: history) }
        #expect(history == ["a", "b"])
        for number in 0..<30 { history = CommandHistory.adding("line \(number)", to: history) }
        #expect(history.count == CommandHistory.limit && history.first == "line 29")
    }

    // MARK: Child processes

    private func sh(_ script: String, collects: Bool = true) -> ProcessRunner {
        ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            directory: nil,
            collectsOutput: collects
        )
    }

    /// Standard output, standard error and the exit status of a child are collected.
    @Test
    internal func outputAndStatusAreCollected() {
        let outcome = sh("echo out; echo err 1>&2; exit 3").run(cancellation: CancellationFlag(), progress: nil)
        #expect(
            outcome.output == "out\nerr\n" && outcome.status == 3 && outcome.failure == nil && !outcome.wasCancelled
        )
    }

    /// A child that writes more than a pipe holds is not blocked.
    @Test
    internal func aLotOfOutputDoesNotBlockTheChild() {
        // Far more than a pipe holds: the child would wait for ever if nobody read.
        var reported = 0
        let outcome = sh("head -c 3000000 /dev/zero | tr '\\0' x")
            .run(cancellation: CancellationFlag()) { bytes in
                reported = max(reported, bytes)
            }
        #expect(outcome.output.utf8.count == 3_000_000 && outcome.status == 0 && !outcome.isTruncated)
    }

    /// Cancelling ends the child, and what it wrote before is kept.
    @Test
    internal func cancellingEndsTheChild() {
        let cancellation = CancellationFlag()
        Thread {
            Thread.sleep(forTimeInterval: 0.2)
            cancellation.cancel()
        }
        .start()
        let started = Date()
        let outcome = sh("echo before; sleep 30").run(cancellation: cancellation, progress: nil)
        #expect(outcome.wasCancelled && Date().timeIntervalSince(started) < 10)
        #expect(outcome.output == "before\n")
    }

    /// A program that does not exist is a failure, not a status.
    @Test
    internal func aProgramThatDoesNotExistIsAFailure() {
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/nonexistent/program"),
            arguments: [],
            directory: nil
        )
        #expect(runner.run(cancellation: CancellationFlag(), progress: nil).failure != nil)
    }

    /// The output of a detached command is not read.
    @Test
    internal func aDetachedCommandIsNotReadFrom() {
        let outcome = sh("echo unseen", collects: false).run(cancellation: CancellationFlag(), progress: nil)
        #expect(outcome.output.isEmpty && outcome.status == 0)
    }

    /// Several children run at once, each with its own output.
    @Test
    internal func severalChildrenRunAtOnce() {
        let outputs = Parallel.map(Array(0..<8)) { number in
            sh("echo \(number)").run(cancellation: CancellationFlag(), progress: nil).output
        }
        #expect(outputs == (0..<8).map { "\($0)\n" })
    }

    // MARK: System information

    /// The information is laid out with its values in one column.
    @Test
    internal func informationIsLaidOutInAlignedColumns() {
        let information = SystemInformation(sections: [
            .init(
                title: "Hardware",
                rows: [.init(label: "Model", value: "Mac"), .init(label: "CPU cores", value: "8")]
            ),
            .init(title: "Volumes", rows: [.init(label: "Disk", value: "/: 1 k of 2 k free")])
        ])
        #expect(
            information.text == "Hardware\n  Model:     Mac\n  CPU cores: 8\n\nVolumes\n  Disk:      /: 1 k of 2 k free"
        )
    }

    /// Memory, time since start and free space are written as the dialog writes them.
    @Test
    internal func formatsFollowTheDialog() {
        #expect(SystemInformation.memory(128 << 30) == "131,072 M (128 G)")
        #expect(SystemInformation.memory(UInt64(1.5 * Double(1 << 30))) == "1,536 M (1.5 G)")
        #expect(SystemInformation.memory(512 << 20) == "512 M")
        #expect(SystemInformation.uptime(130 * 3_600 + 19 * 60 + 21) == "130h 19m 21s")
        #expect(SystemInformation.space(free: 2_048, total: 4_096 * 1_024) == "2 k of 4,096 k free")
        #expect(SystemInformation.space(free: nil, total: 1) == "size unknown")
    }

    /// The system answers the questions System Information asks.
    @Test
    internal func theSystemAnswers() throws {
        let gathered = SystemInformation.gather(displays: ["1x1"], cancellation: CancellationFlag(), asking: .system)
        let information = try #require(gathered)
        #expect(information.sections.map(\.title) == ["Hardware", "Software", "Volumes"])
        #expect(information.sections[0].rows.contains { $0.label == "Display" && $0.value == "1x1" })
        #expect(
            (SystemInformation.systemNumber("hw.ncpu") ?? 0) > 0
                && SystemInformation.systemText("kern.ostype") == "Darwin"
        )
        #expect(SystemInformation.systemText("no.such.value") == nil && !information.sections[2].rows.isEmpty)
    }

    /// Volume names are checked: not empty, not too long, without / or :, not starting with a dot.
    @Test
    internal func volumeNamesAreChecked() {
        #expect(VolumeName.problem(with: "Work Disk 2") == nil && VolumeName.problem(with: "Диск") == nil)
        #expect(
            VolumeName.problem(with: "") != nil && VolumeName.problem(with: "a/b") != nil
                && VolumeName.problem(with: "a:b") != nil
        )
        #expect(
            VolumeName.problem(with: ".hidden") != nil
                && VolumeName.problem(with: String(repeating: "x", count: 300)) != nil
        )
    }
}
