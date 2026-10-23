import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Secrets and questions (review 2: N088, N091, N099, N104, N105, and the mark on downloads N009).
@Suite
internal struct Review2NetworkSecrets {
    /// What one run of the askpass helper gave.
    private struct AskpassRun {
        /// What the helper wrote for ssh.
        let output: String
        /// How the helper ended.
        let status: Int32
        /// The question as the program received it.
        let question: AskpassHelper.Question
    }

    /// Runs the helper's program as ssh does and answers the question it brings with `answer`.
    ///
    /// The program gets `prompt`, and `SSH_ASKPASS_PROMPT` is set to `kind` when there is one.
    private func ask(_ helper: AskpassHelper, _ prompt: String, kind: String?, answer: String) throws -> AskpassRun {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\"$SSH_ASKPASS\" \"$0\"", prompt]
        process.environment = helper.environment.merging(kind.map { ["SSH_ASKPASS_PROMPT": $0] } ?? [:]) { _, new in
            new
        }
        process.standardOutput = output
        try process.run()
        var question: AskpassHelper.Question?
        let end = Date().addingTimeInterval(Wait.ceiling)
        while question == nil, Date() < end {
            question = helper.pendingQuestion()
            if question == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        let asked = try #require(question)
        helper.reply(answer, to: asked)
        process.waitUntilExit()
        return AskpassRun(
            output: String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            status: process.terminationStatus,
            question: asked
        )
    }

    /// A question of ssh is told by its shape, and a server's text cannot pass for one of this Mac's.
    @Test
    internal func aQuestionOfTheSecureShellIsToldByItsShape() {
        #expect(
            SSHQuestion("alice@files.example.com's password: ") == .password(user: "alice", host: "files.example.com")
        )
        // A user name may hold an `@`; the host is what follows the last one.
        #expect(
            SSHQuestion("alice@corp.example@files.example.com's password:")
                == .password(user: "alice@corp.example", host: "files.example.com")
        )
        #expect(
            SSHQuestion("(bob@jump.example.net) Verification code: ")
                == .server(user: "bob", host: "jump.example.net", text: "Verification code:")
        )
        #expect(SSHQuestion("Enter passphrase for key '/Users/a/.ssh/id_ed25519': ") == .passphrase)
        let hostKey =
            "The authenticity of host 'h (1.2.3.4)' can't be established.\n"
            + "ED25519 key fingerprint is SHA256:x.\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        #expect(SSHQuestion(hostKey) == .hostKey)
        #expect(SSHQuestion("Password:") == .other)
        // What a server writes cannot pass for a question of this Mac or for a confirmation.
        let forged = "(alice@files.example.com) Enter passphrase for key '/Users/a/.ssh/id_ed25519': "
        guard case .server = SSHQuestion(forged) else {
            Issue.record("a server's text was taken for ssh's own")
            return
        }
        #expect(SSHQuestion(forged).shown(forged).contains("comes from the server"))
        #expect(SSHQuestion("(a@h) Continue (yes/no)? ") != .hostKey && SSHQuestion("Type (yes/no to go on") == .other)
        #expect(SSHQuestion("Password:").shown("Password:").contains("may come from the server"))
        #expect(SSHQuestion("a@h's password:").shown("a@h's password:") == "a@h's password:")
    }

    /// The stored password answers only a password question that names this user on this host.
    @Test
    internal func theStoredPasswordGoesToThisLoginOnly() {
        let profile = ConnectionProfile(
            key: ServerKey(scheme: "sftp", host: "files.example.com"),
            user: "alice@corp.example",
            password: "pw"
        )
        #expect(SFTPSession.asksForPassword("alice@corp.example@files.example.com's password: ", of: profile))
        #expect(SFTPSession.asksForPassword("(alice@corp.example@files.example.com) Password: ", of: profile))
        #expect(!SFTPSession.asksForPassword("alice@corp.example's password: ", of: profile))
        #expect(!SFTPSession.asksForPassword("Password: ", of: profile), "a question that names nobody")
        #expect(!SFTPSession.asksForPassword("(alice@corp.example@files.example.com) Enter passphrase: ", of: profile))
        #expect(!SFTPSession.asksForPassword("(alice@corp.example@files.example.com) One-time code: ", of: profile))
    }

    /// ssh is started with the options that keep a server's settings from running anything here.
    @Test
    internal func theArgumentsForTheSecureShell() {
        var values = NetworkOptions.Values()
        (values.timeout, values.keepAliveInterval) = (20, 0)
        let arguments = SFTPSession.sshArguments(
            for: ConnectionProfile(key: ServerKey(scheme: "sftp", host: "h"), user: "u"),
            options: values
        )
        for option in [
            "RemoteCommand=none", "PermitLocalCommand=no", "ControlMaster=no", "ControlPath=none", "LogLevel=ERROR",
            "ServerAliveCountMax=3"
        ] {
            #expect(arguments.contains(option), "\(option)")
        }
        // The line is watched also when the user wants no keep-alive of the program's own.
        #expect(arguments.contains("ServerAliveInterval=20") && arguments.contains("-T"))
        #expect(arguments.suffix(4) == ["-s", "--", "h", "sftp"])
    }

    /// An answer written for a helper that is gone is not given to the next question.
    @Test
    internal func anAnswerLeftBehindDoesNotAnswerTheNextQuestion() throws {
        let helper = try AskpassHelper(in: FileManager.default.temporaryDirectory)
        // Written for a helper that ssh has ended meanwhile: nobody takes it.
        helper.reply("the old secret", to: AskpassHelper.Question(id: "1.1", kind: .entry, text: "old"))
        let first = try ask(helper, "alice@h's password: ", kind: nil, answer: "the new secret")
        #expect(
            first.output == "the new secret\n" && first.question.kind == .entry
                && first.question.text == "alice@h's password: "
        )
        // A question of several lines arrives whole.
        let second = try ask(helper, "line one\nline two? ", kind: nil, answer: "yes")
        #expect(second.question.text == "line one\nline two? " && second.output == "yes\n")
        #expect(second.question.id != first.question.id)
        // A confirmation is answered by how the helper ends, and a notice wants no answer.
        let allowed = try ask(helper, "Allow use of key?", kind: "confirm", answer: "yes")
        #expect(allowed.question.kind == .confirm && allowed.status == 0 && allowed.output.isEmpty)
        #expect(try ask(helper, "Allow use of key?", kind: "confirm", answer: "no").status != 0)
        #expect(try ask(helper, "Touch your security key", kind: "none", answer: "").question.kind == .notice)
    }

    /// An address is never shown with its password, and what only looks like one is left alone.
    @Test
    internal func noAddressIsShownWithItsPassword() {
        #expect(ServerAddress.removingPassword(from: "user:secret@host.example") == "user@host.example")
        #expect(ServerAddress.removingPassword(from: "smb://u:se/cr#et?@nas.local/share") == "smb://u@nas.local/share")
        #expect(ServerAddress.removingPassword(from: "host.example:2121/pub") == "host.example:2121/pub")
        #expect(ServerAddress.removingPassword(from: "ftp://host/a:b@c") == "ftp://host/a:b@c")
    }

    /// A file from a server gets the quarantine mark of a download, naming the program; a local one gets none.
    @Test
    internal func whatComesFromAServerIsMarkedAsDownloaded() throws {
        let center = ConnectionCenter()
        center.agentName = "Some; Program"
        let fileSystem = RemoteFileSystem(scheme: "sftp", center: center)
        let mark = try #require(
            fileSystem.quarantine(of: ServerKey(scheme: "sftp", host: "h").url(path: "/tool.command"))
        )
        let text = try #require(String(bytes: mark, encoding: .utf8))
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        #expect(fields.count == 4 && fields[0] == "0083" && fields[2] == "Some  Program" && fields[3].isEmpty)
        let stamp = try #require(Int(fields[1], radix: 16))
        #expect(abs(Double(stamp) - Date().timeIntervalSince1970) < 3_600)
        #expect(fileSystem.quarantine(of: URL(fileURLWithPath: "/tmp/x")) == nil)
        #expect(
            RemoteFileSystem.quarantineMark(agent: "A", at: Date(timeIntervalSince1970: 255)) == Data("0083;ff;A;".utf8)
        )
    }

    /// A name goes back to the server in the bytes and the form it came in, over FTP and SFTP.
    @Test
    internal func aNameGoesBackToTheServerAsItCame() throws {
        let names = NameMemory()
        // Not UTF-8 on the server: read as Western Latin 1, and written back as the same bytes.
        let read = NameEncoding.automatic.decodeTelling(Data([0x47, 0x72, 0xFC, 0xDF, 0x65]))
        #expect(read.text == "Grüße" && read.encoding == .windowsCP1252)
        #expect(NameMemory.needsRemembering(read.text, readAs: read.encoding, sending: .utf8))
        names.remember(read.text, encoding: read.encoding)
        #expect(
            try NameEncoding.automatic.encode("RETR /pub/Grüße", names: names) == Data("RETR /pub/".utf8)
                + Data([0x47, 0x72, 0xFC, 0xDF, 0x65])
        )
        // Decomposed on the server: not composed on the way back. A name of the Mac's is composed as before.
        #expect(
            NameMemory.needsRemembering("u\u{308}", readAs: .utf8, sending: .utf8)
                && !NameMemory.needsRemembering("ü", readAs: .utf8, sending: .utf8)
        )
        names.remember("u\u{308}.txt", encoding: .utf8)
        #expect(try NameEncoding.utf8.encode("DELE /u\u{308}.txt", names: names) == Data("DELE /u\u{308}.txt".utf8))
        #expect(try NameEncoding.utf8.encode("DELE /o\u{308}.txt", names: names) == Data("DELE /ö.txt".utf8))
        #expect(
            try NameEncoding.utf8.encode("SITE CHMOD 644 /dir/u\u{308}.txt", names: names)
                == Data("SITE CHMOD 644 /dir/u\u{308}.txt".utf8)
        )
        // A character the server's encoding does not have is an error, not a question mark.
        #expect(throws: FileSystemError.self) { try NameEncoding.windowsLatin1.encode("STOR /日本.txt", names: nil) }
        #expect(
            try NameEncoding.windowsLatin1.encode("STOR /Grüße", names: nil) == Data("STOR /Gr".utf8)
                + Data([0xFC, 0xDF, 0x65])
        )
        // The same for the secure shell's packets.
        var packet = SFTPEncoder()
        packet.names = names
        packet.string("/pub/Grüße/o\u{308}")
        #expect(
            packet.data.dropFirst(4) == Data("/pub/".utf8) + Data([0x47, 0x72, 0xFC, 0xDF, 0x65]) + Data("/ö".utf8)
        )
        var decoder = SFTPDecoder(Data([0, 0, 0, 2, 0xFC, 0x41]))
        let name = try decoder.name()
        #expect(name.text == "üA" && name.encoding == .isoLatin1)
    }
}
