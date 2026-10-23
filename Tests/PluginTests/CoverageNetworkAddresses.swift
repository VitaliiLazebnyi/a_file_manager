import Testing

@testable import NetworkPlugin

/// Download lists, addresses and saved connections at their edges.
@Suite
internal struct CoverageNetworkAddresses {
    /// Lines of a download list at their edges.
    @Test
    internal func downloadListLinesAtTheirEdges() {
        let actions = DownloadList.parse("   \nsleep: soon\nmove:\nput:  \n")
        #expect(actions == [.pause(0), .unsupported("move:"), .unsupported("put:")])
    }

    /// Paths with a mark before a slash cannot be separated.
    @Test
    internal func pathsWithAMarkBeforeASlashCannotBeSeparated() {
        #expect(!RemotePath.hasSeparableNames("/a\u{600}/b"))
        #expect(RemotePath.hasSeparableNames("/a/b\u{600}c"))
    }

    /// Empty user names are no user name.
    @Test
    internal func emptyUserNamesAreNoUserName() {
        #expect(ServerAddress("ftp://@host")?.user == nil)
        #expect(ServerAddress("ftp://:secret@host")?.user == nil)
        #expect(ServerAddress("ftp://:secret@host")?.password == "secret")
    }

    /// Bracketed addresses need a number or nothing after them.
    @Test
    internal func bracketedAddressesNeedANumberOrNothingAfterThem() {
        #expect(ServerAddress("[::1]:abc") == nil)
        #expect(ServerAddress("[::1]x") == nil)
        #expect(ServerAddress("[::1]:2121")?.port == 2_121)
    }

    /// Percent signs that encode nothing are kept.
    @Test
    internal func percentSignsThatEncodeNothingAreKept() {
        #expect(ServerAddress("ftp://host/a%zz")?.path == "/a%zz")
        #expect(ServerAddress("ftp://us%zz:pw@host")?.user == "us%zz")
    }

    /// Connection kinds follow scheme and security.
    @Test
    internal func connectionKindsFollowSchemeAndSecurity() {
        #expect(SavedConnection.Kind(scheme: "sftp", tls: .explicit) == .sftp)
        #expect(SavedConnection.Kind(scheme: "ftps", tls: .explicit) == .ftpExplicitTLS)
        #expect(SavedConnection.Kind.ftpExplicitTLS.tls == .explicit)
    }

    /// A port is kept only when it is not the protocol's own.
    @Test
    internal func aPortIsKeptOnlyWhenItIsNotTheProtocolsOwn() {
        var connection = SavedConnection()
        connection.setPort(21)
        #expect(connection.port == nil)
        connection.setPort(2_121)
        #expect(connection.port == 2_121)
    }

    /// User names are written into an address with what a URL cannot hold escaped.
    @Test
    internal func userNamesAreEscapedInAnAddress() {
        #expect(ServerAddress("ftp://j\u{F6}rg:pw@host/pub")?.textWithoutPassword == "ftp://j%C3%B6rg@host/pub")
    }

    /// An IPv6 host is shown in brackets.
    @Test
    internal func anIPv6HostIsShownInBrackets() {
        var connection = SavedConnection()
        connection.host = "fe80::1"
        connection.port = 2_121
        #expect(connection.hostText == "[fe80::1]:2121")
    }

    /// Passwords are not carried onto the same account.
    @Test
    internal func passwordsAreNotCarriedOntoTheSameAccount() {
        let store = MemoryPasswords()
        let vault = PasswordVault(store: store)
        var connection = SavedConnection()
        connection.host = "example.com"
        vault.setPassword("secret", for: connection)
        vault.carryPassword(from: connection, to: connection, removing: true)
        vault.waitUntilDone()
        #expect(store.password(for: PasswordVault.account(of: connection)) == "secret")
        #expect(!vault.hasTrusted(for: "example.com"))
    }
}
