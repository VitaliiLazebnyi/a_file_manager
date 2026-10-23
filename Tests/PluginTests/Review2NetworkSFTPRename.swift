import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Renaming over SFTP (review 2: N005, N034), against a server whose rename does not replace
/// and against the system's own.
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct Review2NetworkSFTPRename {
    /// On a server whose rename does not replace, the old file is moved aside and deleted, and nothing else is left.
    @Test
    internal func aServerWithoutReplacingRenameGetsTheOldFileMovedAside() throws {
        let suite = try NetworkFixSFTP(mode: .strictRename)
        try suite.box.file("srv/new.txt", "new")
        try suite.box.file("srv/keep.txt", "old")
        try suite.fileSystem.move(suite.url("/new.txt"), to: suite.url("/keep.txt"), replacing: true)
        #expect(suite.box.read("srv/keep.txt") == "new" && !suite.box.exists("srv/new.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: suite.box.url("srv").path).sorted() == ["keep.txt"])
    }

    /// A rename the server refuses, or of a source that is not there, leaves both files as they were.
    @Test
    internal func aRefusalForAnotherReasonLosesNothing() throws {
        let suite = try NetworkFixSFTP(mode: .strictRename)
        try suite.box.file("srv/locked", "new")
        try suite.box.file("srv/keep.txt", "old")
        // The source cannot be renamed at all; the file in the way is moved aside and put back.
        #expect(throws: (any Error).self) {
            try suite.fileSystem.move(suite.url("/locked"), to: suite.url("/keep.txt"), replacing: true)
        }
        #expect(suite.box.read("srv/keep.txt") == "old" && suite.box.read("srv/locked") == "new")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: suite.box.url("srv").path).sorted() == [
                "keep.txt", "locked"
            ]
        )
        // A source that is not there.
        #expect(throws: (any Error).self) {
            try suite.fileSystem.move(suite.url("/none"), to: suite.url("/keep.txt"), replacing: true)
        }
        #expect(suite.box.read("srv/keep.txt") == "old")
    }
}
