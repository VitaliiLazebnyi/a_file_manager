import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// The operation log where its file is not what it was: replaced while open, a device, in a folder that cannot be
/// written or listed, without an extension, or rotated onto a name that is taken.
@Suite
internal struct CovFileOpsLog {
    private let box: Sandbox

    /// A sandbox; throws when the disk refuses.
    internal init() throws {
        box = try Sandbox()
    }

    /// A file put in place of the log while it is open is written to from then on.
    @Test
    internal func aFileThatTookTheLogsPlaceIsWrittenTo() throws {
        let file = box.url("operations.log")
        let log = OperationLog(configuration(file, rotation: .never))
        log.write(OperationRecord(.copy, source: "/a/one"))
        log.flushSoon()
        drained(log)
        try FileManager.default.moveItem(at: file, to: box.url("moved.log"))
        try box.file("operations.log", "")
        log.write(OperationRecord(.copy, source: "/a/two"))
        log.flush()
        #expect(box.read("operations.log")?.contains("/a/two") == true)
        #expect(box.read("moved.log")?.contains("/a/two") == false)
    }

    /// A device where the log is to go is not written to.
    @Test
    internal func aDeviceIsNotWrittenTo() {
        let log = OperationLog(configuration(URL(fileURLWithPath: "/dev/null"), rotation: .never))
        log.write(OperationRecord(.delete, source: "/a/one"))
        log.flush()
        var info = stat()
        #expect(stat("/dev/null", &info) == 0 && (info.st_mode & S_IFMT) == S_IFCHR)
    }

    /// A log that cannot be written is not rotated either.
    @Test
    internal func aLogThatCannotBeWrittenIsNotRotated() throws {
        let locked = try box.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let log = OperationLog(configuration(locked.appendingPathComponent("operations.log"), rotation: .size(1)))
        log.write(OperationRecord(.copy, source: "/a/one"))
        log.write(OperationRecord(.copy, source: "/a/two"))
        log.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path).isEmpty)
    }

    /// A log without an extension is rotated to numbered copies; where its folder cannot be listed, none are removed.
    @Test
    internal func aLogWithoutAnExtensionIsRotated() throws {
        let folder = try box.folder("logs")
        var settings = configuration(folder.appendingPathComponent("operations"), rotation: .size(1))
        settings.keepCount = 1
        let log = OperationLog(settings)
        log.write(OperationRecord(.copy, source: "/a/one"))
        log.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o333], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        log.write(OperationRecord(.copy, source: "/a/two"))
        log.flush()
        log.write(OperationRecord(.copy, source: "/a/three"))
        log.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["operations", "operations.1", "operations.2"])
    }

    /// A daily copy whose name is taken gets a number after the date.
    @Test
    internal func aDailyCopyWhoseNameIsTakenGetsANumber() throws {
        let file = box.url("operations.log")
        try box.file("operations.log", "yesterday\n")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        try box.file("operations.\(today).log", "taken\n")
        let tomorrow = Date().addingTimeInterval(86_400 * 2)
        let log = OperationLog(configuration(file, rotation: .daily)) { tomorrow }
        log.write(OperationRecord(.copy, source: "/a/one"))
        log.flush()
        #expect(box.read("operations.\(today)-2.log") == "yesterday\n")
        #expect(box.read("operations.log")?.contains("/a/one") == true)
    }

    /// A log of everything into `file`, rotated as `rotation` says.
    private func configuration(_ file: URL, rotation: OperationLog.Rotation) -> OperationLog.Configuration {
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = file
        configuration.rotation = rotation
        return configuration
    }

    /// Waits until the log's queue has done what was handed to it.
    private func drained(_ log: OperationLog) {
        let done = DispatchSemaphore(value: 0)
        log.onQueue { done.signal() }
        done.wait()
    }
}
