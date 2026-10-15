import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Reading, writing and continuing files when the system says no, and making folders whose way down is blocked.
@Suite
internal struct CoverageLocalFiles {
    /// A file that cannot be looked at is not opened.
    @Test
    internal func aFileThatCannotBeLookedAtIsNotOpened() throws {
        let box = try Sandbox()
        let file = try box.file("a.txt")
        let local = CoverageLocalProbes.failing("fstat", endingIn: "a.txt", EIO)
        #expect { try local.read(file) } throws: { CoverageLocalProbes.code($0) == Int(EIO) }
        let blocking = CoverageLocalProbes.failing("fcntl", endingIn: "a.txt", EBADF)
        #expect { try blocking.read(file) } throws: { CoverageLocalProbes.code($0) == Int(EBADF) }
    }

    /// A reader says what went wrong.
    @Test
    internal func aReaderSaysWhatWentWrong() throws {
        let box = try Sandbox()
        let file = try box.file("a.txt", "hello")
        let reader = try CoverageLocalProbes.failing("read", endingIn: "a.txt", EIO).read(file)
        #expect { try reader.read(upToCount: 4) } throws: { CoverageLocalProbes.code($0) == Int(EIO) }
        let plain = try LocalFileSystem().read(file)
        #expect(try plain.read(upToCount: 0) == nil)
        #expect { try plain.seek(to: .max) } throws: { CoverageLocalProbes.code($0) == Int(EINVAL) }
        try plain.seek(to: 1)
        #expect(try plain.read(upToCount: 2) == Data("el".utf8))
        plain.close()
        #expect { try plain.read(upToCount: 1) } throws: { CoverageLocalProbes.code($0) == Int(EBADF) }
        #expect { try plain.seek(to: 0) } throws: { CoverageLocalProbes.code($0) == Int(EBADF) }
    }

    /// A writer says what went wrong and can be left unclosed.
    @Test
    internal func aWriterSaysWhatWentWrongAndCanBeLeftUnclosed() throws {
        let box = try Sandbox()
        let failing = try CoverageLocalProbes.failing("write", endingIn: "w.txt", ENOSPC).write(box.url("w.txt"))
        #expect { try failing.write(Data("x".utf8)) } throws: { CoverageLocalProbes.code($0) == Int(ENOSPC) }
        try failing.close(attributes: FileAttributes())
        // Closed twice: nothing more happens; writing then is an error.
        try failing.close(attributes: FileAttributes())
        #expect { try failing.write(Data("x".utf8)) } throws: { CoverageLocalProbes.code($0) == Int(EBADF) }
        // A writer let go of without closing closes its file.
        do {
            let dropped = try LocalFileSystem().write(box.url("dropped.txt"))
            try dropped.write(Data("kept".utf8))
        }
        #expect(box.read("dropped.txt") == "kept")
    }

    /// Closing reports the first of its failures.
    @Test
    internal func closingReportsTheFirstOfItsFailures() throws {
        let box = try Sandbox()
        let date = Date(timeIntervalSince1970: 1_000_000)
        // The date fails, then the rights: the date's failure is the one reported.
        var probes = LocalProbes()
        probes.fault = { call, _ in call == "futimens" ? EIO : call == "fchmod" ? EPERM : nil }
        let both = try LocalFileSystem(probes: probes).write(box.url("both.txt"))
        #expect { try both.close(attributes: FileAttributes(modified: date, permissions: 0o600)) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EIO)
        }
        let rights = try CoverageLocalProbes.failing("fchmod", endingIn: "rights.txt", EPERM)
            .write(box.url("rights.txt"))
        #expect { try rights.close(attributes: FileAttributes()) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EPERM)
        }
        let closing = try CoverageLocalProbes.failing("close", endingIn: "close.txt", EIO).write(box.url("close.txt"))
        try closing.write(Data("abc".utf8))
        #expect { try closing.close(attributes: FileAttributes()) } throws: { CoverageLocalProbes.code($0) == Int(EIO) }
        #expect(box.read("close.txt") == "abc")
    }

    /// Continuing a file stops where the system says no.
    @Test
    internal func continuingAFileStopsWhereTheSystemSaysNo() throws {
        let box = try Sandbox()
        let file = try box.file("a.txt", "0123456789")
        // The flag is set while the file is opened: nothing is changed.
        let flag = CancellationFlag()
        var probes = LocalProbes()
        probes.fault = { call, _ in
            if call == "fstat" { flag.cancel() }
            return nil
        }
        #expect { try LocalFileSystem(probes: probes).append(to: file, at: 4, cancellation: flag) } throws: { error in
            (error as? CocoaError)?.code == .userCancelled
        }
        let looking = CoverageLocalProbes.failing("fstat", endingIn: "a.txt", EIO, after: 1)
        #expect { try looking.append(to: file, at: 4, cancellation: CancellationFlag()) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EIO)
        }
        let cutting = CoverageLocalProbes.failing("ftruncate", endingIn: "a.txt", EPERM)
        #expect { try cutting.append(to: file, at: 4, cancellation: CancellationFlag()) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EPERM)
        }
        #expect(box.read("a.txt") == "0123456789")
        // Without an offset the file goes on at its end.
        let writer = try LocalFileSystem().append(to: file, at: nil, cancellation: CancellationFlag())
        try writer.write(Data("ab".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(box.read("a.txt") == "0123456789ab")
    }

    /// A folder above that cannot be made stops the making.
    @Test
    internal func aFolderAboveThatCannotBeMadeStopsTheMaking() throws {
        let box = try Sandbox()
        let locked = try box.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect { try LocalFileSystem().createDirectory(at: box.url("locked/a/b")) } throws: { error in
            CoverageLocalProbes.code(error) == Int(EACCES)
                && (error as NSError).localizedDescription.hasSuffix("locked/a")
        }
    }

    /// A folder that cannot be made on the way down stops the making.
    @Test
    internal func aFolderThatCannotBeMadeOnTheWayDownStopsTheMaking() throws {
        let box = try Sandbox()
        let top = try box.folder("top")
        let (upper, lower) = (top.appendingPathComponent("a"), top.appendingPathComponent("a/b"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: upper.path) }
        // `top/a` is made on the way up; the second time `top/a/b` is asked for (on the way down),
        // `top/a` no longer takes new folders.
        let asked = Shared(0)
        var probes = LocalProbes()
        probes.willAsk = { path in
            guard path == lower.path else {
                return
            }
            asked.modify { $0 += 1 }
            if asked.value == 2 {
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: upper.path)
            }
        }
        #expect {
            try LocalFileSystem(probes: probes).createDirectory(at: top.appendingPathComponent("a/b/c"))
        } throws: { error in
            CoverageLocalProbes.code(error) == Int(EACCES)
        }
        #expect(box.exists("top/a") && !box.exists("top/a/b"))
    }

    /// A change on an automounted folder is made where it can be left behind.
    @Test
    internal func aChangeOnAnAutomountedFolderIsMadeWhereItCanBeLeftBehind() {
        // Automounted home folders: not a disk of this Mac; nothing can be made there by a user.
        let place = URL(fileURLWithPath: "/System/Volumes/Data/home/afm-coverage-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try LocalFileSystem().createDirectory(at: place, cancellation: CancellationFlag())
        }
        #expect(RemoteChanges.shared.strandedCalls(on: "/System/Volumes/Data/home") == 0)
    }
}
