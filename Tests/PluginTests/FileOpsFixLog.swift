import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// The operation log: bursts, the handle, the end of a job and the pruning of old copies.
@Suite
internal struct FileOpsFixLog {
    /// Lines reach the file after a short while without a flush, and keep their order across bursts.
    @Test
    internal func linesAreWrittenWithoutAFlushAfterAShortWhile() throws {
        let box = try Sandbox()
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        let log = OperationLog(configuration)
        for index in 0..<50 { log.write(OperationRecord(.copy, source: "/a/\(index)", target: "/b/\(index)")) }
        var text = ""
        for _ in 0..<300 where text.split(separator: "\n").count < 50 {
            Thread.sleep(forTimeInterval: 0.01)
            text = box.read("logs/operations.log") ?? ""
        }
        #expect(text.split(separator: "\n").count == 50)
        // The end of a job asks for what is collected, and the lines keep their order across bursts.
        log.write(OperationRecord(.copy, source: "/z", target: "/z"))
        log.flushSoon()
        log.flush()
        let lines = (box.read("logs/operations.log") ?? "").split(separator: "\n")
        #expect(lines.count == 51 && lines.last?.hasSuffix("Copy: /z -> /z") == true)
    }

    /// A log file deleted while it was open is made again by the next lines.
    @Test
    internal func aFileThatWasDeletedWhileTheLogWasOpenIsWrittenAgain() throws {
        let box = try Sandbox()
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        let log = OperationLog(configuration)
        // The end of a job writes what is collected and keeps the file open.
        log.write(OperationRecord(.copy, source: "one"))
        log.flushSoon()
        for _ in 0..<200 where !(box.read("logs/operations.log") ?? "").contains("one") {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try FileManager.default.removeItem(at: box.url("logs/operations.log"))
        log.write(OperationRecord(.copy, source: "three"))
        log.flushSoon()
        for _ in 0..<200 where !(box.read("logs/operations.log") ?? "").contains("three") {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(box.read("logs/operations.log")?.contains("three") == true)
        log.flush()
    }

    /// Pruning old copies removes only rotated copies of the log, not other files of a like name.
    @Test
    internal func pruningLeavesOtherPeoplesFilesAlone() throws {
        let box = try Sandbox()
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        configuration.rotation = .size(120)
        configuration.keepCount = 1
        try box.file("logs/operations.backup.log", "mine")
        try box.file("logs/operations.notes.log", "mine")
        let log = OperationLog(configuration)
        for index in 0..<10 {
            log.write(OperationRecord(.copy, source: "/a/" + String(repeating: "x", count: 60) + "\(index)"))
            log.flush()
            Thread.sleep(forTimeInterval: 0.02)
        }
        let names = namesOnDisk(box.url("logs"))
        #expect(names.contains("operations.backup.log") && names.contains("operations.notes.log"))
        #expect(
            names.filter { $0.range(of: #"^operations\.\d+\.log$"#, options: .regularExpression) != nil }.count == 1
        )
    }

    /// Only names made by the rotation count as rotated copies of the log.
    @Test
    internal func theNamesOfRotatedCopiesAreRecognisedExactly() {
        #expect(OperationLog.isRotatedCopy("operations.2026-10-12.log", of: "operations.log"))
        #expect(OperationLog.isRotatedCopy("operations.2026-10-12-3.log", of: "operations.log"))
        #expect(OperationLog.isRotatedCopy("operations.7.log", of: "operations.log"))
        #expect(!OperationLog.isRotatedCopy("operations.log", of: "operations.log"))
        #expect(!OperationLog.isRotatedCopy("operations.backup.log", of: "operations.log"))
        #expect(!OperationLog.isRotatedCopy("operations.7.txt", of: "operations.log"))
        #expect(OperationLog.isRotatedCopy("ops.4", of: "ops"))
    }
}
