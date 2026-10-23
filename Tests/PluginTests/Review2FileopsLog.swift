import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// The operation log: one line per record, rotation, appending after other writers, the flush at quit.
@Suite
internal struct Review2FileopsLog {
    /// A scratch folder whose logs folder holds the log.
    internal let box: Sandbox

    /// A fresh scratch folder.
    internal init() throws {
        box = try Sandbox()
    }

    /// A log that is on, writes to logs/operations.log, rotates as given and keeps no old files.
    private func configuration(_ rotation: OperationLog.Rotation = .never) -> OperationLog.Configuration {
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        configuration.rotation = rotation
        configuration.keepCount = 0
        return configuration
    }

    // F060, F055
    /// A record whose names hold line breaks is still one line in the log.
    @Test
    internal func aNameWithALineBreakIsOneLineInTheLog() {
        let forged = OperationRecord(
            .copy,
            source: "/a/x\n2026-01-01 00:00:00: Delete: /etc/passwd",
            target: "/b/y\r",
            status: .failed("no\nway")
        )
        let line = OperationLog.line(for: forged, at: "T")
        let source = "/a/x<U+000A>2026-01-01 00:00:00: Delete: /etc/passwd"
        #expect(line == "T: Error: Copy: \(source) -> /b/y<U+000D>: no<U+000A>way\n")
        #expect(line.filter { $0 == "\n" }.count == 1)
        #expect(
            OperationLog.line(for: OperationRecord(.delete, source: "/plain/ü name.txt"), at: "T")
                == "T: Delete: /plain/ü name.txt\n"
        )
    }

    // F061
    /// A burst of records that fills the log several times rotates it each time.
    @Test
    internal func aBurstThatFillsTheLogSeveralTimesRotatesEachTime() throws {
        let log = OperationLog(configuration(.size(200)))
        // Twelve lines of 61 bytes in one burst: three fit into a file of 200 bytes.
        for index in 0..<12 {
            log.write(OperationRecord(.copy, source: "/source/folder/file-\(String(format: "%02d", index)).txt"))
        }
        log.flush()
        let files = namesOnDisk(box.url("logs"))
        #expect(files.count == 4, "\(files)")
        for name in files {
            let size =
                (try FileManager.default.attributesOfItem(atPath: box.url("logs/\(name)").path)[.size] as? Int) ?? 0
            #expect(size > 0 && size <= 200, "\(name): \(size)")
        }
    }

    // F062
    /// The log appends at the end even after somebody else emptied it and wrote a line of their own.
    @Test
    internal func theLogAppendsAlsoAfterSomebodyElseEmptiedOrExtendedIt() throws {
        let log = OperationLog(configuration())
        log.write(OperationRecord(.copy, source: "/one"))
        #expect(log.flush(timeout: 30))
        // The handle is let go by `flush`; keep one open across the change with `flushSoon`.
        log.write(OperationRecord(.copy, source: "/two"))
        log.flushSoon()
        log.write(OperationRecord(.copy, source: "/wait"))
        log.flushSoon()
        let file = box.url("logs/operations.log")
        // Wait until the open handle has written, without closing it.
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        var text = ""
        for _ in 0..<2_000 where !text.contains("/wait") {
            text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if !text.contains("/wait") { usleep(5_000) }
        }
        try #require(text.contains("/wait"))
        // Another writer empties the file and writes a line of its own.
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Data("somebody else\n".utf8))
        log.write(OperationRecord(.copy, source: "/three"))
        log.flush()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2 && lines[0] == "somebody else" && lines[1].hasSuffix("Copy: /three"))
    }

    // F027
    /// The flush at quit writes what is pending within its time.
    @Test
    internal func theFlushAtQuitGivesUpAfterItsTime() throws {
        let log = OperationLog(configuration())
        log.write(OperationRecord(.copy, source: "/one"))
        #expect(log.flush(timeout: 30))
        #expect(try String(contentsOf: box.url("logs/operations.log"), encoding: .utf8).hasSuffix("Copy: /one\n"))
    }
}
