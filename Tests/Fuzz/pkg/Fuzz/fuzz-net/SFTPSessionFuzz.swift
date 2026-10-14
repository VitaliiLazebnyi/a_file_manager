import AFMKernel
import Foundation
import FuzzCore

@testable import NetworkPlugin

/// The `sftpsession` target: a whole session against a "server" that says what the input holds.
internal enum SFTPSessionFuzz {
    /// The session environment, made once by `setUp`.
    @MainActor private static var environment: SessionEnvironment?

    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    @MainActor
    internal static func target() -> FuzzTarget {
        FuzzTarget("sftpsession", maxLen: 3_000, seeds: seeds, setUp: setUp, run: run)
    }

    /// A number in four bytes, big-endian.
    ///
    /// - Parameter value: The number.
    /// - Returns: The bytes.
    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]
    }

    /// A string as SFTP sends it: its length, then its bytes.
    ///
    /// - Parameter text: The string.
    /// - Returns: The bytes.
    private static func string(_ text: String) -> [UInt8] {
        bigEndian(UInt32(text.utf8.count)) + Array(text.utf8)
    }

    /// One answer of the input: the kind index, a short length, the session's own request number, the body.
    ///
    /// - Parameters:
    ///   - kind: The index of the kind (0 status, 1 handle, 2 data, 3 name, 4 attributes).
    ///   - body: The body.
    /// - Returns: The bytes of the input.
    private static func part(_ kind: UInt8, _ body: [UInt8]) -> [UInt8] {
        [kind, 1, UInt8(body.count), 1] + body
    }

    /// The answers to connecting, listing the home folder, asking for a file and reading it.
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        let realpath = bigEndian(1) + string("/home/u") + string("/home/u") + bigEndian(0)
        let handle = string("H1")
        let names =
            bigEndian(2) + string("a.txt") + string("long") + bigEndian(5) + [0, 0, 0, 0, 0, 0, 0, 9]
            + bigEndian(0o100644) + string("ln") + string("long") + bigEndian(4) + bigEndian(0o120777)
        let attrs = bigEndian(4) + bigEndian(0o040755)
        let eof = bigEndian(1) + string("eof") + string("")
        let success = bigEndian(0) + string("") + string("")
        let data = string("file data")
        return [
            part(3, realpath) + part(1, handle) + part(3, names) + part(4, attrs) + part(0, eof) + part(0, success)
                + part(4, attrs) + part(1, handle) + part(2, data) + part(0, eof) + part(0, success)
        ]
    }

    /// Makes the session environment: a short timeout, nothing remembered about declined servers.
    @MainActor
    private static func setUp() {
        let options = NetworkOptions()
        var values = options.values
        values.timeout = 1
        options.values = values
        let made = SessionEnvironment(options: options)
        made.declineMemory = 0
        environment = made
    }

    /// The answers framed as a server sends them (length, type, the request numbers in the order the
    /// session asks); their bodies are the input's.
    ///
    /// - Parameter bytes: The input.
    /// - Returns: What the "server" sends.
    private static func conversation(_ bytes: [UInt8]) -> Data {
        var choices = Choices(bytes)
        var out: [UInt8] = []
        func packet(_ kind: UInt8, requestID: UInt32?, _ body: [UInt8]) {
            out += bigEndian(UInt32(1 + (requestID == nil ? 0 : 4) + body.count)) + [kind]
            if let requestID {
                out += bigEndian(requestID)
            }
            out += body
        }
        packet(2, requestID: nil, [0, 0, 0, 3])
        var requestID: UInt32 = 1
        let kinds: [UInt8] = [101, 102, 103, 104, 105, 201, 104, 104, 102]
        while !choices.atEnd, requestID < 40 {
            let kind = kinds[choices.int(kinds.count)]
            let length = choices.int(4) == 0 ? Int(choices.u16()) % 600 : Int(choices.byte())
            packet(kind, requestID: choices.int(16) == 0 ? UInt32(choices.byte()) : requestID, choices.take(length))
            requestID += 1
        }
        return Data(out)
    }

    /// Connects, lists the home folder, asks for a file and reads it.
    ///
    /// One process (`/bin/cat`) per input.
    ///
    /// - Parameter bytes: The input.
    @MainActor
    private static func run(_ bytes: [UInt8]) {
        guard let environment else {
            preconditionFailure("setUp makes the environment before the first run")
        }

        let file = fzWorkDir + "/conversation.bin"
        FileManager.default.createFile(atPath: file, contents: conversation(bytes))
        let profile = ConnectionProfile(key: ServerKey(scheme: "sftp", host: "fuzz.invalid"), user: "u")
        let session = SFTPSession(
            profile: profile,
            environment: environment,
            transport: SFTPTransport(executable: "/bin/cat", arguments: [file])
        )
        defer { session.disconnect() }
        guard let home = try? session.connect(cancellation: nil) else {
            return
        }

        var seen: [RemoteEntry] = []
        try? session.list(home, showHidden: true, cancellation: nil) { entries in
            seen += entries
            return seen.count < 10_000
        }
        for entry in seen {
            _ = entry.item(in: NetFuzz.base)
        }
        _ = try? session.entry(at: home + "/a.txt", cancellation: nil)
        if let reader = try? session.openRead(home + "/a.txt", cancellation: nil) {
            var total = 0
            while let block = try? reader.read(upToCount: 32_768), total < 1 << 20 {
                total += block.count
            }
            reader.close()
        }
    }
}
