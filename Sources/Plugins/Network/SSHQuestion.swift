import Foundation

/// What a question of `ssh` is, told by the words ssh itself puts around it.
///
/// A server can make ssh show any text it likes (keyboard-interactive logins, and a jump host can
/// do the same), so a question is only taken for ssh's own when it has exactly the shape ssh gives
/// it, and everything a server may have written is shown to the user as the server's.
internal enum SSHQuestion: Equatable {
    /// An unknown host key, to be answered with `yes` or `no`.
    case hostKey
    /// Anything else: who asks cannot be told, so it may be the server.
    case other
    /// `Enter passphrase for key '…':`, about a key on this Mac.
    case passphrase
    /// `user@host's password:`, asked by ssh itself.
    case password(user: String, host: String)
    /// `(user@host) text`: a keyboard-interactive login.
    ///
    /// The text is the server's.
    case server(user: String, host: String, text: String)

    /// Tells what a question of ssh is; surrounding white space is ignored.
    internal init(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("("), let close = text.range(of: ") "),
            let login = Self.login(in: text[text.index(after: text.startIndex)..<close.lowerBound])
        {
            self = .server(user: login.user, host: login.host, text: String(text[close.upperBound...]))
        } else if text.hasPrefix("("), text.hasSuffix(")"), let login = Self.login(in: text.dropFirst().dropLast()) {
            self = .server(user: login.user, host: login.host, text: "")
        } else if text.hasPrefix("The authenticity of host "), text.contains("(yes/no") {
            self = .hostKey
        } else if text.hasPrefix("Please type 'yes'") {
            self = .hostKey
        } else if text.hasPrefix("Enter passphrase for ") || text.hasPrefix("Enter PIN for ") {
            self = .passphrase
        } else if let end = text.range(of: "'s password:", options: [.caseInsensitive, .backwards]),
            end.upperBound == text.endIndex,
            !text.contains("\n"), let login = Self.login(in: text[..<end.lowerBound])
        {
            self = .password(user: login.user, host: login.host)
        } else {
            self = .other
        }
    }

    /// `user@host`, cut at the last `@`: a host has none, a user name may.
    ///
    /// Nil when there is no user or no host, or the host holds white space.
    private static func login(in text: Substring) -> (user: String, host: String)? {
        guard let atSign = text.lastIndex(of: "@") else {
            return nil
        }
        let host = String(text[text.index(after: atSign)...]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard atSign > text.startIndex, !host.isEmpty, !host.contains(where: \.isWhitespace) else {
            return nil
        }
        return (String(text[..<atSign]), host)
    }

    /// The question as the user is shown it: what a server wrote is marked as the server's, so
    /// it cannot pass for a question of this Mac (`Enter passphrase for key …`).
    internal func shown(_ question: String) -> String {
        switch self {
        case .server(_, let host, let text):
            return "The server \(host) asks (this text comes from the server):\n\n\(text)"

        case .other:
            return "The secure shell passes on this question, which may come from the server:\n\n\(question)"

        case .password, .passphrase, .hostKey:
            return question
        }
    }
}
