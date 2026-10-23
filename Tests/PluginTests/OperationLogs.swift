import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// The operation log (spec 13 › Operation › Log file).
@Suite
internal struct OperationLogs {
    /// A clock the test moves.
    ///
    /// Unchecked: the test moves it only while no line is being written.
    internal final class Clock: @unchecked Sendable {
        /// The time the log reads; 2026-10-12 at first.
        internal var now = Date(timeIntervalSince1970: 1_791_813_787)

        deinit {
            // Nothing to release.
        }
    }

    /// The folder the log files go to.
    internal let box: Sandbox
    /// A log that is on and writes to `logs/operations.log` in the sandbox.
    internal var configuration = OperationLog.Configuration()

    /// A fresh sandbox and a log configuration that writes into it.
    internal init() throws {
        box = try Sandbox()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
    }

    /// Records become dated lines in the order they were written, with failures and skips marked.
    @Test
    internal func linesAreWrittenInOrderOffTheCallingThread() {
        let clock = Clock()
        let log = OperationLog(configuration) { clock.now }
        log.write(OperationRecord(.copy, source: "/a/one.txt", target: "/b/one.txt"))
        log.write(OperationRecord(.delete, source: "/a/two.txt", status: .failed("Permission denied")))
        log.write(OperationRecord(.move, source: "/a/three.txt", target: "/b/three.txt", status: .skipped))
        log.flush()
        let lines = (box.read("logs/operations.log") ?? "").split(separator: "\n").map { String($0.dropFirst(21)) }
        #expect(
            lines == [
                "Copy: /a/one.txt -> /b/one.txt", "Error: Delete: /a/two.txt: Permission denied",
                "Skipped: Move: /a/three.txt -> /b/three.txt"
            ]
        )
        #expect(
            box.read("logs/operations.log")?
                .range(
                    of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d: Copy"#,
                    options: .regularExpression
                ) != nil
        )
    }

    /// Records written from many threads at once all arrive, each on a line of its own.
    @Test
    internal func manyThreadsCanWriteAtOnce() {
        let log = OperationLog(configuration)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            log.write(OperationRecord(.copy, source: "/a/\(index)", target: "/b/\(index)"))
        }
        log.flush()
        let lines = (box.read("logs/operations.log") ?? "").split(separator: "\n")
        #expect(lines.count == 200 && Set(lines.map { $0.split(separator: " ").last ?? "" }).count == 200)
    }

    /// Deletes, skips and folders can be left out of the log, and a log that is off writes no file.
    @Test
    internal func onlyWhatIsWantedIsLogged() {
        var quiet = configuration
        quiet.logsDeletes = false
        quiet.logsSkipped = false
        quiet.logsFolders = false
        let log = OperationLog(quiet)
        log.write(OperationRecord(.copy, source: "kept"))
        log.write(OperationRecord(.copy, source: "skipped", status: .skipped))
        log.write(OperationRecord(.trash, source: "trashed"))
        log.write(OperationRecord(.makeFolder, source: "folder"))
        log.write(OperationRecord(.rename, source: "failed", status: .failed("no")))
        log.flush()
        let text = box.read("logs/operations.log") ?? ""
        #expect(
            text.contains("kept") && text.contains("Error: Rename: failed: no") && !text.contains("skipped")
                && !text.contains("trashed")
                && !text.contains("folder")
        )

        var off = configuration
        off.isEnabled = false
        off.file = box.url("logs/off.log")
        let silent = OperationLog(off)
        silent.write(OperationRecord(.copy, source: "x"))
        silent.flush()
        #expect(!box.exists("logs/off.log"))
    }

    /// A log that grows past its size starts again, keeping only as many old copies as asked.
    @Test
    internal func rotationBySizeKeepsALimitedNumberOfCopies() {
        var rotating = configuration
        rotating.rotation = .size(200)
        rotating.keepCount = 2
        let log = OperationLog(rotating)
        for index in 0..<12 {
            log.write(OperationRecord(.copy, source: "/a/" + String(repeating: "x", count: 60) + "\(index)"))
            log.flush()
            // The copies are told apart by their dates.
            Thread.sleep(forTimeInterval: 0.02)
        }
        let names = namesOnDisk(box.url("logs"))
        #expect(names.contains("operations.log") && names.count == 3)
        #expect(names.allSatisfy { $0.hasPrefix("operations.") && $0.hasSuffix(".log") })
        #expect((box.read("logs/operations.log") ?? "").utf8.count <= 200)
    }

    /// A daily log moves the last day's file aside under its date when a new day's line comes.
    @Test
    internal func dailyRotationStartsANewFileAfterMidnight() throws {
        var rotating = configuration
        rotating.rotation = .daily
        let clock = Clock()
        let log = OperationLog(rotating) { clock.now }
        log.write(OperationRecord(.copy, source: "today"))
        log.flush()
        // The file was last written two days ago, as far as the disk knows.
        let before = Date(timeIntervalSinceNow: -2 * 86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: before],
            ofItemAtPath: box.url("logs/operations.log").path
        )
        clock.now = Date()
        log.write(OperationRecord(.copy, source: "later"))
        log.flush()
        let names = namesOnDisk(box.url("logs"))
        #expect(names.count == 2 && box.read("logs/operations.log")?.contains("later") == true)
        let old = try #require(names.first { $0 != "operations.log" })
        #expect(
            old.range(of: #"^operations\.\d{4}-\d\d-\d\d\.log$"#, options: .regularExpression) != nil
                && box.read("logs/" + old)?.contains("today") == true
        )
    }
}
