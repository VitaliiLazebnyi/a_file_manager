import Foundation
import Testing

@testable import NetworkPlugin

/// How a connection's local folder with a leading `~` becomes a path.
@Suite
internal struct NetworkTildeTests {
    /// `~` alone and `~/...` go to the current user's home folder.
    @Test
    internal func tildeIsTheCurrentUsersHome() {
        #expect("~".expandingTilde == NSHomeDirectory())
        #expect("~/Music/Live".expandingTilde == NSHomeDirectory() + "/Music/Live")
    }

    /// `~user/...` goes to that user's home folder; an unknown user leaves the path as it is.
    @Test
    internal func tildeWithANameIsThatUsersHome() {
        #expect("~root/notes".expandingTilde == "/var/root/notes")
        #expect("~no-such-user-afm/notes".expandingTilde == "~no-such-user-afm/notes")
    }

    /// A path without a leading `~` stays as it is, a `~` further on included.
    @Test
    internal func otherPathsStayAsTheyAre() {
        #expect("/tmp/a~b".expandingTilde == "/tmp/a~b")
        #expect("".expandingTilde.isEmpty)
    }
}
