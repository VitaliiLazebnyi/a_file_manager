import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Server addresses as typed, server keys, remote paths and saved connections.
@Suite
internal struct NetworkAddressTests {
    /// Typed addresses give scheme, user, password, host, port and path; panel URLs carry no credentials.
    @Test
    internal func addresses() throws {
        var address = try #require(ServerAddress("ftp.example.com"))
        #expect(
            address.scheme == "ftp" && address.port == 21 && address.user == nil && address.path == "/"
                && !address.hasPath
        )
        #expect(address.url.absoluteString == "ftp://ftp.example.com/")

        address = try #require(ServerAddress("myself@myserver.com:1021"))
        #expect(
            address.user == "myself" && address.password == nil && address.host == "myserver.com"
                && address.port == 1_021
        )
        #expect(address.url.absoluteString == "ftp://myserver.com:1021/")

        address = try #require(ServerAddress("ftp://anna:p%40ss:w@rd@Host.Example.com:2121/home/my%20user/"))
        #expect(
            address.user == "anna" && address.password == "p@ss:w@rd" && address.path == "/home/my user"
                && address.hasPath
        )
        // The URL for the panel carries no credentials; the remembered text no password.
        #expect(address.url.absoluteString == "ftp://host.example.com:2121/home/my%20user")
        #expect(address.textWithoutPassword == "ftp://anna@host.example.com:2121/home/my%20user")
        #expect(!address.textWithoutPassword.contains("ss"))

        address = try #require(ServerAddress("FTPS://secure.example.com"))
        #expect(address.scheme == "ftps" && address.tls == .explicit && address.port == 21)
        #expect(ServerAddress("ftps://secure.example.com:990")?.tls == .implicit)
        address = try #require(ServerAddress("ftpis://secure.example.com"))
        #expect(
            address.tls == .implicit && address.port == 990
                && address.url.absoluteString == "ftps://secure.example.com:990/"
        )
        address = try #require(ServerAddress("ftpes://secure.example.com:990/x"))
        #expect(address.tls == .explicit && address.port == 990)
        address = try #require(ServerAddress("sftp://deploy@box.local/var/www"))
        #expect(
            address.scheme == "sftp" && address.port == 22 && address.user == "deploy"
                && address.url.absoluteString == "sftp://box.local/var/www"
        )

        address = try #require(ServerAddress("[1234:56:789A:BC::DE]:2100"))
        #expect(address.host == "1234:56:789A:BC::DE" && address.port == 2_100)
        #expect(ServerKey(address.url) == address.key && address.key.host == "1234:56:789a:bc::de")
        #expect(ServerAddress("::1")?.host == "::1")
        address = try #require(ServerAddress("sftp://[fe80::1]/srv"))
        #expect(address.host == "fe80::1" && address.port == 22 && address.path == "/srv")

        for bad in ["", "http://www.example.com", "host:port", "host:99999", "ftp://", "two words", "[::1", "user@"] {
            #expect(ServerAddress(bad) == nil)
        }
    }

    /// Server keys ignore case and the default port; remote paths are normalised, split and joined.
    @Test
    internal func serverKeysAndPaths() {
        let key = ServerKey(scheme: "FTP", host: "Example.COM", port: nil)
        #expect(
            key.description == "ftp://example.com"
                && key.url(path: "pub/a b").absoluteString == "ftp://example.com/pub/a%20b"
        )
        #expect(ServerKey(scheme: "sftp", host: "h").port == 22)
        #expect(URL(string: "ftp://example.com:21/x").flatMap(ServerKey.init) == key)
        #expect(
            ServerKey(URL(fileURLWithPath: "/tmp")) == nil
                && URL(string: "http://example.com/").flatMap(ServerKey.init) == nil
        )
        let odd = key.url(path: "/a#b?c%d;e")
        #expect(RemotePath.of(odd) == "/a#b?c%d;e" && ServerKey(odd) == key)
        #expect(
            RemotePath.normalized("a//b/./c/../d/") == "/a/b/d" && RemotePath.normalized("") == "/"
                && RemotePath.normalized("/../..") == "/"
        )
        #expect(
            RemotePath.parent(of: "/a/b") == "/a" && RemotePath.parent(of: "/a") == "/"
                && RemotePath.parent(of: "/") == nil
        )
        #expect(RemotePath.name(of: "/a/b.txt") == "b.txt" && RemotePath.join("/a/", "b") == "/a/b")
    }

    /// A saved connection takes the host as typed, and its profile carries what was set.
    @Test
    internal func savedConnections() {
        var connection = SavedConnection()
        var accepted = connection.setHost("ftp.example.com:2121", kind: .ftp)
        #expect(accepted && connection.port == 2_121 && connection.hostText == "ftp.example.com:2121")
        #expect(connection.key.description == "ftp://ftp.example.com:2121")
        accepted = connection.setHost("ftpis://anna@secure.example.com/start", kind: .ftp)
        #expect(
            accepted && connection.kind == .ftpImplicitTLS && connection.port == nil && connection.key.port == 990
                && connection.user == "anna"
        )
        #expect(
            connection.remoteDirectory == "/start" && connection.profile.tls == .implicit
                && connection.profile.user == "anna"
        )
        accepted = connection.setHost("box", kind: .sftp)
        #expect(accepted && connection.key == ServerKey(scheme: "sftp", host: "box", port: 22))
        accepted = connection.setHost("not a host", kind: .ftp)
        #expect(!accepted)
        connection.anonymous = true
        connection.listing = .list
        connection.initCommands = "SITE A;SITE B"
        let profile = connection.profile
        #expect(
            profile.user == nil && profile.anonymous && profile.listing == .list
                && profile.initCommands == ["SITE A", "SITE B"]
        )
        #expect(profile.savedID == connection.id)
    }
}
