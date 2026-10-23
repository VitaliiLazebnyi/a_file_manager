import Foundation
import Testing

@testable import ConfigurationPlugin

/// A leading `~` in a start folder or an application path, read as a shell reads it.
@Suite
internal struct ShellWordsTildeTests {
    /// `~` alone and `~/…` stand for the user's home folder; a `~` further on stays.
    @Test
    internal func aTildeAtTheStartIsTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ShellWords.expandingTilde(in: "~") == home)
        #expect(ShellWords.expandingTilde(in: "~/Tools/a b") == home + "/Tools/a b")
        #expect(ShellWords.expandingTilde(in: "/tmp/~x") == "/tmp/~x")
    }

    /// `~user` is that user's home folder; a user nobody knows leaves the path as it is.
    @Test
    internal func aTildeWithANameIsThatUsersHomeFolder() throws {
        let root = try #require(FileManager.default.homeDirectory(forUser: "root")).path
        #expect(ShellWords.expandingTilde(in: "~root/x") == root + "/x")
        #expect(ShellWords.expandingTilde(in: "~afm-nobody-here/x") == "~afm-nobody-here/x")
    }
}
