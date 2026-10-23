import Foundation

/// Lets `ssh` ask its questions (a password, the passphrase of a key, an unknown host key)
/// through this program instead of a terminal: `SSH_ASKPASS` points to a tiny script that
/// writes the question into one named pipe and reads the answer from another.
///
/// Nothing secret is ever put into the environment, on the command line or into a file. Used by one
/// thread.
///
/// Every run of the script gives its question a number of its own and takes only the answer
/// that carries it: an answer that was written for a script which ssh had ended meanwhile
/// stays in the pipe, and must not answer the next question.
internal final class AskpassHelper {
    /// What ssh wants from the helper (`SSH_ASKPASS_PROMPT`).
    internal enum Kind: Equatable {
        /// A text to be typed: a password, a passphrase, or `yes` to a host key.
        case entry
        /// Yes or no (the touch of a security key to be allowed).
        case confirm
        /// Nothing to answer: a notice (touch the security key now).
        case notice
    }

    /// One question of one run of the script.
    internal struct Question: Equatable {
        /// The number the script gave the question; the answer must carry it.
        internal let id: String
        /// What kind of answer ssh wants.
        internal let kind: Kind
        /// The question as ssh put it.
        internal let text: String
    }

    /// More than this is not collected while a question has no end.
    private static let longestQuestion = 64 * 1_024

    /// The folder of the pipes and the script; removed with the helper.
    internal let directory: URL
    private let question: Int32
    private let answer: Int32
    private let endMarker = "END-" + UUID().uuidString
    private var received = Data()

    /// What the child process needs in its environment.
    internal var environment: [String: String] {
        [
            "SSH_ASKPASS": directory.appendingPathComponent("askpass.sh").path, "SSH_ASKPASS_REQUIRE": "force",
            "AFM_ASKPASS_QUESTION": directory.appendingPathComponent("question").path,
            "AFM_ASKPASS_ANSWER": directory.appendingPathComponent("answer").path, "AFM_ASKPASS_END": endMarker
        ]
    }

    /// The pipes and the script go into a new folder in `parent`, normally the user's temporary folder.
    internal init(in parent: URL) throws {
        directory = parent.appendingPathComponent("afm-askpass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let (questionPath, answerPath) = (
            directory.appendingPathComponent("question").path, directory.appendingPathComponent("answer").path
        )
        guard mkfifo(questionPath, 0o600) == 0, mkfifo(answerPath, 0o600) == 0 else {
            // Nothing is left behind of a helper that could not be made.
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EIO)
        }
        // Opened for reading and writing, so neither end blocks or sees an end of file while
        // the script comes and goes.
        question = open(questionPath, O_RDWR | O_NONBLOCK)
        answer = open(answerPath, O_RDWR | O_NONBLOCK)
        let script = """
            #!/bin/sh
            id="$$.$(date +%s)"
            kind="${SSH_ASKPASS_PROMPT:-}"
            printf '%s\\n%s\\n%s\\n%s\\n' "$id" "$kind" "$1" "$AFM_ASKPASS_END" > "$AFM_ASKPASS_QUESTION"
            exec 3< "$AFM_ASKPASS_ANSWER"
            reply=
            while IFS= read -r line <&3; do
              case "$line" in
                "$id "*) reply=${line#"$id "}; break ;;
              esac
            done
            if [ "$kind" = confirm ]; then
              [ "$reply" = yes ] && exit 0
              exit 1
            fi
            printf '%s\\n' "$reply"

            """
        let scriptURL = directory.appendingPathComponent("askpass.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    /// A question that has arrived completely; nil when there is none.
    internal func pendingQuestion() -> Question? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(question, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(buffer, count: count)
            if received.count > Self.longestQuestion {
                received.removeFirst(received.count - Self.longestQuestion)
            }
        }
        let text = String(repairingUTF8: received)
        guard let end = text.range(of: "\n" + endMarker + "\n") else {
            return nil
        }
        received = Data(text[end.upperBound...].utf8)
        // The number, what ssh wants, and the question, which may have lines of its own.
        let parts = text[..<end.lowerBound].split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        let kind: Kind = parts[1] == "confirm" ? .confirm : parts[1] == "none" ? .notice : .entry
        return Question(id: String(parts[0]), kind: kind, text: String(parts[2]))
    }

    /// Answers `question`, and no other.
    internal func reply(_ text: String, to question: Question) {
        // One line; a line break inside would be read as the end of the answer.
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let line = Data((question.id + " " + first).utf8) + Data([0x0A])
        _ = line.withUnsafeBytes { write(answer, $0.baseAddress, $0.count) }
    }

    deinit {
        close(question)
        close(answer)
        try? FileManager.default.removeItem(at: directory)
    }
}
