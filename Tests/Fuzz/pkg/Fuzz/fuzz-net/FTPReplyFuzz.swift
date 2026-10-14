import AFMKernel
import Foundation
import FuzzCore

@testable import NetworkPlugin

/// The `ftpreply` target: the replies of an FTP server, line by line, and what is read out of them.
internal enum FTPReplyFuzz {
    /// Tokens of FTP replies.
    private static let dict = [
        "227 Entering Passive Mode (192,168,1,2,19,137)", "229 Entering Extended Passive Mode (|||6446|)",
        "211-Features:", "211 End", " MLST type*;size*;modify*;", " UTF8", "257 \"/a \"\"quoted\"\" name\" created",
        "213 20240102030405.123", "220-", "220 ", "-", "(", ")", "|", ",", "\"", "\"\"", "99999999999999999999", "256",
        "65536", "0,0,0,0,0,0", ";;", ";", "+ ", "- ", "\\"
    ]

    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    internal static func target() -> FuzzTarget {
        FuzzTarget("ftpreply", maxLen: 2_048, dict: dict, seeds: seeds, run: run)
    }

    /// A greeting and the replies a session reads.
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        [
            "220-Welcome\n line two\n220 ready\n227 Entering Passive Mode (192,168,1,2,19,137)\n"
                + "229 Entering Extended Passive Mode (|||6446|)\n211-Features:\n MLST type*;size*;\n UTF8\n211 End\n"
                + "257 \"/a \"\"q\"\" n\" created\n213 20240102030405\n",
            "150\n226-x\n226\n", "500 no\n227 =1,2,3,4,5,6\n229 (!!!1!)\n",
            "SITE A;;B; SITE C ;\nsrc -> dst\n+ a/b\n- c\n"
        ]
        .map { Array($0.utf8) }
    }

    /// Feeds the lines to a reply parser and reads every line as each kind of reply.
    ///
    /// - Parameter bytes: The input.
    private static func run(_ bytes: [UInt8]) {
        var parser = FTPReplyParser()
        for raw in NetFuzz.lines(bytes) {
            let line = NetFuzz.text(raw)
            if let reply = parser.feed(line) {
                fzCheck((0...999).contains(reply.code), "ftpreply-code", "\(reply.code)")
                _ = FTPSyntax.features(reply)
                _ = FTPConnection.requiresSessionReuse(reply)
                for replyLine in reply.lines {
                    _ = FTPSyntax.quotedPath(replyLine)
                }
            }
            readLine(line, length: raw.count)
        }
        _ = DownloadList.parse(NetFuzz.text(bytes))
    }

    /// Reads one line as a passive mode reply, a path, a time, a port argument and init commands.
    ///
    /// - Parameters:
    ///   - line: The line.
    ///   - length: Its length in bytes (used as a port).
    private static func readLine(_ line: String, length: Int) {
        if let port = FTPSyntax.extendedPassivePort(line) {
            fzCheck((1...65_535).contains(port), "epsv-port", "\(port) from \(line.debugDescription)")
        }
        if let end = FTPSyntax.passiveEndpoint(line) {
            fzCheck((1...65_535).contains(end.port), "pasv-port", "\(end.port) from \(line.debugDescription)")
            _ = FTPSyntax.portArgument(host: end.host, port: end.port)
            _ = FTPSyntax.extendedPortArgument(host: end.host, port: end.port)
        }
        _ = FTPSyntax.quotedPath(line)
        if let time = FTPSyntax.time(line) {
            _ = FTPSyntax.timeText(time)
        }
        _ = FTPSyntax.portArgument(host: line, port: length)
        _ = FTPServerConfig.initCommands(from: line)
    }
}
