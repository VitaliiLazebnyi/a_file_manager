import Foundation

/// Taking passwords out of addresses before they are remembered or shown.
extension ServerAddress {
    /// An address of any scheme (`smb://user:password@host/share`, also without the scheme) as
    /// it may be remembered and shown: the password is taken out, the user name stays.
    ///
    /// A password may contain `/`, `?` and `#`, so the end of the server part cannot be found
    /// by the first of them alone: when the part before it holds a colon but no `@`, and an
    /// `@` follows later, what stands between that colon and the last `@` is taken for a
    /// password, unless it starts like a port (`host:445/share/a@b`). Rather a name too many
    /// taken out of a remembered address than a password shown.
    internal static func removingPassword(from text: String) -> String {
        let start = text.range(of: "://")?.upperBound ?? text.startIndex
        let rest = text[start...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        var atSign = authority.lastIndex(of: "@")
        if atSign == nil, let colon = authority.firstIndex(of: ":"),
            let later = rest[authorityEnd...].lastIndex(of: "@")
        {
            let afterColon = authority[authority.index(after: colon)...]
            let looksLikePort = !afterColon.isEmpty && afterColon.allSatisfy { $0.isASCII && $0.isNumber }
            if !looksLikePort { atSign = later }
        }
        guard let atSign, let colon = rest[..<atSign].firstIndex(of: ":") else {
            return text
        }
        var cleaned = text
        cleaned.removeSubrange(colon..<atSign)
        return cleaned
    }
}
