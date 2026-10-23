import Foundation
import Testing

@testable import FileOperationsPlugin

/// How the path of the log file is read: a leading `~` stands for a home folder, as in a shell.
@Suite
internal struct OperationSettingsTildeTests {
    /// `~` and `~/` stand for the user's own home folder, `~user` for that user's.
    @Test
    internal func aTildeStandsForAHomeFolder() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(OperationSettings.expandingTilde(in: "~") == home)
        #expect(OperationSettings.expandingTilde(in: "~/Logs/a.log") == home + "/Logs/a.log")
        let root = try #require(FileManager.default.homeDirectory(forUser: "root")).path
        #expect(OperationSettings.expandingTilde(in: "~root/a.log") == root + "/a.log")
    }

    /// A path without a tilde, and one naming a user nobody knows, stay as they are.
    @Test
    internal func otherPathsStayAsTheyAre() {
        #expect(OperationSettings.expandingTilde(in: "/var/log/a.log") == "/var/log/a.log")
        #expect(OperationSettings.expandingTilde(in: "a~/b") == "a~/b")
        #expect(OperationSettings.expandingTilde(in: "~nobody-here-at-all/a.log") == "~nobody-here-at-all/a.log")
    }
}
