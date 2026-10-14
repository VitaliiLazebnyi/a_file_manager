import Foundation
import FuzzCore

@testable import NetworkPlugin

/// What the network targets share: the text of an input, its lines, and the checks of what a parser gives.
internal enum NetFuzz {
    /// The folder a listing is read in.
    internal static let base: URL = {
        guard let url = URL(string: "ftp://example.com/dir/") else {
            preconditionFailure("the base URL is valid")
        }
        return url
    }()

    /// The time a listing is read at (a year is guessed from it).
    internal static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// The bytes as UTF-8 text; what is not UTF-8 becomes U+FFFD, as `String(decoding:as:)` does it.
    ///
    /// - Parameter bytes: The bytes.
    /// - Returns: The text.
    internal static func text(_ bytes: [UInt8]) -> String {
        fzText(bytes)
    }

    /// The lines of the input (LF, and CR LF), empty ones kept.
    ///
    /// - Parameter bytes: The input.
    /// - Returns: The lines without their line ends.
    internal static func lines(_ bytes: [UInt8]) -> [[UInt8]] {
        bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { part in
                var line = Array(part)
                if line.last == 0x0D {
                    line.removeLast()
                }
                return line
            }
    }

    /// Checks a listed entry: what becomes a row of a panel has a name that is one path component.
    ///
    /// - Parameter entry: The entry a parser gave, if any.
    internal static func check(_ entry: RemoteEntry?) {
        guard let entry else {
            return
        }

        fzCheck(
            RemoteEntry.isSafeName(entry.name) || entry.name.contains("\\"),
            "ftplist-unsafe-name",
            entry.name.debugDescription
        )
        // By bytes: a `/` that carries a combining mark is one character with it, and still a separator.
        let raw = Array(entry.name.utf8)
        fzCheck(
            !raw.contains(0x2F) && raw != [0x2E] && raw != [0x2E, 0x2E] && !raw.isEmpty && !raw.contains(0),
            "ftplist-name-is-a-path",
            entry.name.debugDescription
        )
        _ = entry.item(in: base)
    }

    /// Asks a saved connection everything the connection list asks it.
    ///
    /// - Parameter connection: The connection.
    internal static func exercise(_ connection: SavedConnection) {
        _ = connection.key.description
        _ = connection.hostText
        _ = connection.listTitle
        let profile = connection.profile
        _ = profile.key.url(path: connection.remoteDirectory)
        _ = ServerKey(profile.key.url())
    }
}
