import Testing

@testable import NetworkPlugin

/// Addresses and prompts that carry secrets.
@Suite
internal struct NetworkFixSecrets {
    /// The password is taken out of an address of any scheme, with or without a scheme, and nothing else.
    @Test
    internal func aPasswordIsNotRemembered() {
        #expect(
            ServerAddress.removingPassword(from: "smb://alice:s3cret@files.example.com/share")
                == "smb://alice@files.example.com/share"
        )
        #expect(
            ServerAddress.removingPassword(from: "https://bob:p%40ss@dav.example.com:8443/a/b?x=1")
                == "https://bob@dav.example.com:8443/a/b?x=1"
        )
        #expect(ServerAddress.removingPassword(from: "afp://carol@host/vol") == "afp://carol@host/vol")
        #expect(
            ServerAddress.removingPassword(from: "nfs://host/export:with:colons@here")
                == "nfs://host/export:with:colons@here"
        )
        #expect(ServerAddress.removingPassword(from: "smb://") == "smb://")
        // Also without a scheme, and with a slash in the password.
        #expect(ServerAddress.removingPassword(from: "no scheme:pw@host") == "no scheme@host")
        #expect(ServerAddress.removingPassword(from: "smb://u:pa/ss@h/share") == "smb://u@h/share")
        #expect(ServerAddress.removingPassword(from: "smb://host:445/share/a@b") == "smb://host:445/share/a@b")
        #expect(ServerAddress.removingPassword(from: "smb://u:p:w@h/s") == "smb://u@h/s")
    }

    /// The stored password answers only the password question that names this server and user (any user
    /// when the profile has none); other hosts, users and questions get nothing.
    @Test
    internal func theStoredPasswordAnswersOnlyThisServersPrompt() {
        let profile = ConnectionProfile(
            key: ServerKey(scheme: "sftp", host: "Files.Example.com"),
            user: "alice",
            password: "pw"
        )
        let asks = { (question: String) in SFTPSession.asksForPassword(question, of: profile) }
        #expect(asks("alice@files.example.com's password: "))
        #expect(asks("(alice@files.example.com) Password: "))
        // A question that names nobody may come from anyone; the user is asked instead.
        #expect(!asks("Password: "))
        // A jump host, or the same host with another user, gets nothing.
        #expect(!asks("bob@jump.example.net's password: "))
        #expect(!asks("alice@jump.example.net's password: "))
        #expect(!asks("bob@files.example.com's password: "))
        #expect(!asks("(jumper@jump.example.net) Password: "))
        // Other questions are no request for the password.
        #expect(!asks("Enter passphrase for key '/Users/a/.ssh/id_ed25519': "))
        #expect(!asks("Are you sure you want to continue connecting (yes/no/[fingerprint])? "))

        let literal = ConnectionProfile(key: ServerKey(scheme: "sftp", host: "[::1]"), user: "alice", password: "pw")
        #expect(SFTPSession.asksForPassword("alice@::1's password: ", of: literal))
        #expect(!SFTPSession.asksForPassword("alice@::2's password: ", of: literal))
        let anyUser = ConnectionProfile(key: ServerKey(scheme: "sftp", host: "h.example"), password: "pw")
        #expect(SFTPSession.asksForPassword("whoever@h.example's password: ", of: anyUser))
    }
}
