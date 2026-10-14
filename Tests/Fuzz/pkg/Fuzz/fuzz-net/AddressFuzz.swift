import AFMKernel
import Foundation
import FuzzCore

@testable import NetworkPlugin

/// The `address` target: what a user types as a server address, and the remote paths made of it.
internal enum AddressFuzz {
    /// Tokens of addresses.
    private static let dict = [
        "ftp://", "ftps://", "sftp://", "ftpes://", "://", "@", ":", "/", "[", "]", "[::1]", "%", "%00", "%2F", "%40",
        "%ZZ", "%E0%A4%A", "99999999999999999999", ":0", ":65536", ":-1", ":21", "user:pass@", "//", "?", "#", " ",
        "\u{0}", "..", "é", "xn--"
    ]

    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    internal static func target() -> FuzzTarget {
        FuzzTarget("address", maxLen: 1_024, dict: dict, seeds: seeds, run: run)
    }

    /// Addresses with users, passwords, ports and odd paths.
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        [
            "ftp://user:p%40ss@host.example.com:2121/pub/dir", "sftp://[2001:db8::1]:22/home", "host", "host:21",
            "ftps://host/", "user@host/path with space/%41", "ftp://a:b:c@d@e:99/", "[::1]", "sftp://u@h/~/../x//y/./z",
            "ftp://host:99999999999999999999/", "://", "ftp://%zz:%@:/"
        ]
        .map { Array($0.utf8) }
    }

    /// Reads up to eight lines as addresses and as remote paths.
    ///
    /// - Parameter bytes: The input.
    private static func run(_ bytes: [UInt8]) {
        for raw in NetFuzz.lines(bytes).prefix(8) {
            let typed = NetFuzz.text(raw)
            for scheme in ["ftp", "sftp", "ftps"] {
                guard let address = ServerAddress(typed, defaultScheme: scheme) else {
                    continue
                }

                checkAddress(address, typed: typed, scheme: scheme)
            }
            _ = ServerAddress.removingPassword(from: typed)
            _ = ServerKey.bare(typed)
            checkPath(typed)
            if let url = URL(string: typed) {
                _ = ServerKey(url)
                _ = RemotePath.of(url)
            }
            var connection = SavedConnection()
            for kind in SavedConnection.Kind.allCases where connection.setHost(typed, kind: kind) {
                NetFuzz.exercise(connection)
            }
            _ = SFTPSession.asksForPassword(
                typed,
                of: ConnectionProfile(key: ServerKey(scheme: "sftp", host: "host"), user: "u")
            )
        }
    }

    /// Checks an address that was read: its path is absolute, the text shown has no password.
    ///
    /// - Parameters:
    ///   - address: The address.
    ///   - typed: What it was read from.
    ///   - scheme: The scheme it was read with.
    private static func checkAddress(_ address: ServerAddress, typed: String, scheme: String) {
        fzCheck(
            address.path.hasPrefix("/"),
            "address-path-not-absolute",
            "\(typed.debugDescription) -> \(address.path.debugDescription)"
        )
        let shown = address.textWithoutPassword
        if let password = address.password, passwordIsTelling(password, in: address) {
            fzCheck(
                !shown.contains(password),
                "address-password-shown",
                "\(typed.debugDescription) -> \(shown.debugDescription)"
            )
        }
        _ = ServerAddress(shown, defaultScheme: scheme)
        let key = ServerKey(scheme: address.scheme, host: address.host, port: address.port)
        let url = key.url(path: address.path)
        _ = ServerKey(url)
        _ = RemotePath.of(url)
        _ = key.description
    }

    /// Whether finding the password in the text shown means it was shown: it is long enough and is
    /// no part of what is shown anyway.
    ///
    /// - Parameters:
    ///   - password: The password.
    ///   - address: The address it is in.
    /// - Returns: Whether the check applies.
    private static func passwordIsTelling(_ password: String, in address: ServerAddress) -> Bool {
        // (The user name is shown percent-encoded: its escapes may spell the password by chance.)
        let shownUser = (address.user ?? "").addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? ""
        return password.count >= 6 && !(address.user ?? "").contains(password) && !shownUser.contains(password)
            && !address.host.contains(password) && !address.path.contains(password)
            && !address.scheme.contains(password) && !String(address.port).contains(password)
    }

    /// Checks the normalized form of a remote path and asks the other path helpers.
    ///
    /// - Parameter typed: The path.
    private static func checkPath(_ typed: String) {
        let normalized = RemotePath.normalized(typed)
        // By bytes, as a server reads the path: it begins with a slash and no part of it is empty, `.` or `..`.
        let parts = Array(normalized.utf8).split(separator: 0x2F, omittingEmptySubsequences: false).map(Array.init)
        fzCheck(
            normalized.utf8.first == 0x2F && (normalized.utf8.count == 1 || !parts.dropFirst().contains([]))
                && !parts.contains([0x2E, 0x2E]) && !parts.contains([0x2E]),
            "remotepath-normalized",
            "\(typed.debugDescription) -> \(normalized.debugDescription)"
        )
        _ = RemotePath.parent(of: typed)
        _ = RemotePath.name(of: typed)
        _ = RemotePath.join(typed, typed)
    }
}
